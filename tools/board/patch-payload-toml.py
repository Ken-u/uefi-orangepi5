#!/usr/bin/env python3
"""Rewrite \\EFI\\UniXNU\\unixnu.toml inside a payload.img: drop the "Power off" (shutdown) entry.

Why: `unixnu build payload` always appends the entries `reset` and `shutdown`. On this board shutdown is PSCI SYSTEM_OFF: the board
loses its power rail and nothing remote can bring it back (no reset controller, no switchable supply; the Orange Pi 5 has no
power button, it starts when the supply is plugged in). The menu is drawn on the HDMI frame buffer and reads the serial console,
so a stray key can pick it. The payload keeps `xnu` and `reset` (SYSTEM_RESET, the board starts again by itself).

    patch-payload-toml.py PAYLOAD.img [--check]

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


def strip_shutdown(text):
    head, *blocks = re.split(r"(?m)^(?=\[\[entry\]\])", text)
    kept = [b for b in blocks if not re.search(r'(?m)^\s*action\s*=\s*"shutdown"\s*$', b)]
    return head + "".join(kept), len(blocks) - len(kept)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    image = sys.argv[1]
    check = "--check" in sys.argv[2:]
    text = mt("mtype", "-i", image, TOML, capture_output=True).stdout.decode()
    new, dropped = strip_shutdown(text)
    if check:
        print("a shutdown entry is still there" if dropped else "ok: no shutdown entry")
        return 1 if dropped else 0
    if not dropped:
        print("ok: no shutdown entry, nothing to change")
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
    print("ok: dropped %d shutdown entry; entries left: %s" % (dropped, ", ".join(re.findall(r'(?m)^id\s*=\s*"([^"]+)"', after))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
