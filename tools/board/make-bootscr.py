#!/usr/bin/env python3
"""Turn a U-Boot script (text) into a boot.scr, the legacy image format `mkimage -T script` writes. No U-Boot tools needed.

    make-bootscr.py boot.cmd boot.scr [--name "UniXNU launcher"] [--table-end 0xffffffff]

The file is: a 64-byte legacy uImage header (magic 0x27051956, CRC of the header, time 0 so the output does not change from run to
run, size, load/entry 0, CRC of the data, OS linux, arch arm64, type script, no compression, name) followed by the data, which for
a script is a list of image sizes (the script length, then a terminator, both big endian) and the text.

With `--table-end 0` this is what `mkimage -A arm64 -O linux -T script -C none -n NAME -d boot.cmd boot.scr` writes with
SOURCE_DATE_EPOCH=0. The default is 0xffffffff because that is what the Orange Pi 5's own U-Boot (a Rockchip-derived one with bootstd)
needs: it counts the entries of a script image until a word of 0xffffffff, not until 0, so with a 0 terminator it ran past the end of
the file and took the script text from the wrong place (`Unknown command '<garbage>'`). Hardware-observed (2026-11-03): with
[length, 0xffffffff] `iminfo` lists one image and `source` runs the text; with [length, 0] iminfo listed 287 images (up to the
first 0xffffffff after the file) and `source` printed garbage. The text starts at data + 8 in both cases.
"""
import argparse
import struct
import sys
import zlib

IH_MAGIC = 0x27051956
IH_OS_LINUX = 5
IH_ARCH_ARM64 = 22
IH_TYPE_SCRIPT = 6
IH_COMP_NONE = 0


def make(script: bytes, name: str, table_end: int = 0xFFFFFFFF) -> bytes:
    data = struct.pack(">II", len(script), table_end) + script
    name_bytes = name.encode()[:31].ljust(32, b"\0")
    header = struct.pack(">IIIIIIIBBBB32s", IH_MAGIC, 0, 0, len(data), 0, 0, zlib.crc32(data) & 0xFFFFFFFF,
                         IH_OS_LINUX, IH_ARCH_ARM64, IH_TYPE_SCRIPT, IH_COMP_NONE, name_bytes)
    header = header[:4] + struct.pack(">I", zlib.crc32(header) & 0xFFFFFFFF) + header[8:]
    return header + data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("--name", default="UniXNU launcher")
    parser.add_argument("--table-end", type=lambda text: int(text, 0), default=0xFFFFFFFF,
                        help="word after the script length: 0 is what mkimage writes, 0xffffffff (default) is what the board's U-Boot needs")
    args = parser.parse_args()
    with open(args.source, "rb") as handle:
        script = handle.read()
    if not script.endswith(b"\n"):
        script += b"\n"
    with open(args.output, "wb") as handle:
        handle.write(make(script, args.name, args.table_end))
    return 0


if __name__ == "__main__":
    sys.exit(main())
