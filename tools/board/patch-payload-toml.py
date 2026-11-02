#!/usr/bin/env python3
"""Rewrite \\EFI\\UniXNU\\unixnu.toml inside a payload.img: drop the "Power off" (shutdown) entry and add boot variants.

Why: `unixnu build payload` always appends the entries `reset` and `shutdown`. On this board shutdown is PSCI SYSTEM_OFF: the board
loses its power rail and nothing remote can bring it back (no reset controller, no switchable supply; the Orange Pi 5 has no
power button, it starts when the supply is plugged in). The menu is drawn on the HDMI frame buffer and reads the serial console,
so a stray key can pick it. The payload keeps `xnu` and `reset` (SYSTEM_RESET, the board starts again by itself).

It also adds three entries after `xnu`, copies of it with other boot arguments, so that a variant can be tried from the menu
(any key stops the countdown, Up/Down, Enter) without building another payload:

    xnu-hdmi      + vc_mirror=1             the kernel log is drawn on the HDMI frame buffer as well as sent to the serial port
    xnu-probe     nvme=1 nvme-probe=4096    find and read the NVMe drive, publish nothing (the kernel then waits for a root and restarts)
    xnu-ramdata   nvme-data-persist=0       the Data volume lives in RAM; the drive is only read

    patch-payload-toml.py PAYLOAD.img [--default ID] [--timeout SECONDS] [--check]

--default / --timeout set the menu's default entry and countdown (`[boot] default`, `[boot] timeout`). `unixnu build payload` writes
`xnu` and 3 seconds; the first run on a board wants `xnu-probe` and time to read the screen, because a missed key would start the
normal boot (which writes the Data window of the drive).

Uses mtools (MTOOLS_BIN names its directory when it is not on PATH). --check only reports (exit 1 while a shutdown entry is
there); running it twice is harmless.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

MTOOLS = os.environ.get("MTOOLS_BIN", "")
TOML = "::/EFI/UniXNU/unixnu.toml"


def mt(tool, *args, **kw):
    exe = os.path.join(MTOOLS, tool) if MTOOLS else shutil.which(tool) or tool
    return subprocess.run([exe, *args], check=True, **kw)


VARIANTS = (
    ("xnu-hdmi", "UniXNU Orange Pi 5 (kernel log on HDMI too)", {"vc_mirror": "1"}),
    ("xnu-probe", "UniXNU Orange Pi 5 (probe the NVMe drive only)", {"nvme": "1", "nvme-probe": "4096"}),
    ("xnu-ramdata", "UniXNU Orange Pi 5 (Data in RAM)", {"nvme-data-persist": "0"}),
)


def set_args(args, changes):
    tokens = args.split()
    for name, value in changes.items():
        for index, token in enumerate(tokens):
            if token.split("=")[0] == name:
                tokens[index] = "%s=%s" % (name, value)
                break
        else:
            tokens.append("%s=%s" % (name, value))
    return " ".join(tokens)


def add_variants(text):
    """Insert the VARIANTS after the xnu entry; entries that exist are left alone. Returns (text, number added)."""
    head, *blocks = re.split(r"(?m)^(?=\[\[entry\]\])", text)
    ids = [re.search(r'(?m)^id\s*=\s*"([^"]+)"', b).group(1) for b in blocks]
    if "xnu" not in ids:
        raise SystemExit("no entry with id xnu in the payload's unixnu.toml")
    base = blocks[ids.index("xnu")]
    added = []
    for variant_id, title, changes in VARIANTS:
        if variant_id in ids:
            continue
        block = re.sub(r'(?m)^id\s*=.*$', 'id = "%s"' % variant_id, base, count=1)
        block = re.sub(r'(?m)^title\s*=.*$', 'title = "%s"' % title, block, count=1)
        args = re.search(r'(?m)^args\s*=\s*"([^"]*)"', block).group(1)
        block = re.sub(r'(?m)^args\s*=.*$', lambda m: 'args = "%s"' % set_args(args, changes), block, count=1)
        added.append(block)
    at = ids.index("xnu") + 1
    return head + "".join(blocks[:at] + added + blocks[at:]), len(added)


def set_boot(text, default=None, timeout=None):
    """Set `default` and `timeout` in the [boot] table (the text before the first [[entry]]). Returns the new text."""
    head, sep, rest = text.partition("[[entry]]")
    m = re.search(r"(?ms)^\[boot\]\s*$(.*?)(?=^\[|\Z)", head)
    if not m:
        raise SystemExit("no [boot] table in the payload's unixnu.toml")
    body = m.group(1)
    if default is not None:
        ids = re.findall(r'(?m)^id\s*=\s*"([^"]+)"', rest)
        if default not in ids:
            raise SystemExit("no entry with id %s (entries: %s)" % (default, ", ".join(ids)))
        body, n = re.subn(r'(?m)^default\s*=.*$', 'default = "%s"' % default, body)
        if not n:
            body = body.rstrip("\n") + '\ndefault = "%s"\n' % default
    if timeout is not None:
        body, n = re.subn(r"(?m)^timeout\s*=.*$", "timeout = %d" % timeout, body)
        if not n:
            body = body.rstrip("\n") + "\ntimeout = %d\n" % timeout
    return head[:m.start(1)] + body + head[m.end(1):] + sep + rest


def boot_table(text):
    head = text.partition("[[entry]]")[0]
    m = re.search(r"(?ms)^\[boot\]\s*$(.*?)(?=^\[|\Z)", head)
    body = m.group(1) if m else ""
    d = re.search(r'(?m)^default\s*=\s*"([^"]*)"', body)
    t = re.search(r"(?m)^timeout\s*=\s*(\d+)", body)
    return (d.group(1) if d else None), (int(t.group(1)) if t else None)


def strip_shutdown(text):
    head, *blocks = re.split(r"(?m)^(?=\[\[entry\]\])", text)
    kept = [b for b in blocks if not re.search(r'(?m)^\s*action\s*=\s*"shutdown"\s*$', b)]
    return head + "".join(kept), len(blocks) - len(kept)


def option(argv, name):
    if name in argv:
        index = argv.index(name)
        if index + 1 >= len(argv):
            raise SystemExit("%s needs a value" % name)
        return argv[index + 1]
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    image = sys.argv[1]
    check = "--check" in sys.argv[2:]
    want_default = option(sys.argv, "--default")
    want_timeout = option(sys.argv, "--timeout")
    want_timeout = int(want_timeout) if want_timeout is not None else None
    text = mt("mtype", "-i", image, TOML, capture_output=True).stdout.decode()
    new, dropped = strip_shutdown(text)
    if check:
        missing = [v[0] for v in VARIANTS if 'id = "%s"' % v[0] not in text]
        default, timeout = boot_table(text)
        wrong = []
        if want_default is not None and default != want_default:
            wrong.append("default is %s, wanted %s" % (default, want_default))
        if want_timeout is not None and timeout != want_timeout:
            wrong.append("timeout is %s, wanted %s" % (timeout, want_timeout))
        print("a shutdown entry is still there" if dropped else "ok: no shutdown entry" + ("; missing variants: %s" % ", ".join(missing) if missing else "")
              + ("; %s" % "; ".join(wrong) if wrong else "") + "; menu default %s, countdown %s s" % (default, timeout))
        return 1 if dropped or missing or wrong else 0
    new, added = add_variants(new)
    new = set_boot(new, want_default, want_timeout)
    if new == text:
        print("ok: no shutdown entry, variants present, nothing to change")
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as handle:
        handle.write(new)
        name = handle.name
    try:
        mt("mcopy", "-o", "-i", image, name, TOML)
    finally:
        os.unlink(name)
    after = mt("mtype", "-i", image, TOML, capture_output=True).stdout.decode()
    assert "shutdown" not in after, "the shutdown entry survived the rewrite"
    default, timeout = boot_table(after)
    print("ok: dropped %d shutdown entry, added %d variants; entries: %s; menu default %s, countdown %s s"
          % (dropped, added, ", ".join(re.findall(r'(?m)^id\s*=\s*"([^"]+)"', after)), default, timeout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
