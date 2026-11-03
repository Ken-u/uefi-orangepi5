#!/usr/bin/env python3
"""Host test of make-bootscr.py: header fields, both CRCs, the size table and where the text starts.

    python3 tools/board/test-bootscr.py
"""
import importlib.util
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_bootscr", os.path.join(HERE, "make-bootscr.py"))
make_bootscr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_bootscr)

SCRIPT = b"echo hello\nif true; then echo yes; fi\n"


def check(table_end: int) -> None:
    image = make_bootscr.make(SCRIPT, "name") if table_end == 0xFFFFFFFF else make_bootscr.make(SCRIPT, "name", table_end)
    magic, hcrc, time, size, load, entry, dcrc, os_, arch, kind, comp, name = struct.unpack(">IIIIIIIBBBB32s", image[:64])
    data = image[64:]
    assert magic == 0x27051956, "magic"
    assert time == 0 and load == 0 and entry == 0, "time/load/entry"
    assert (os_, arch, kind, comp) == (5, 22, 6, 0), "os/arch/type/compression"
    assert name.rstrip(b"\0") == b"name", "name"
    assert size == len(data), "data size %d != %d" % (size, len(data))
    assert zlib.crc32(data) & 0xFFFFFFFF == dcrc, "data crc"
    assert zlib.crc32(image[:4] + b"\0\0\0\0" + image[8:64]) & 0xFFFFFFFF == hcrc, "header crc"
    length, end = struct.unpack(">II", data[:8])
    assert length == len(SCRIPT), "script length"
    assert end == table_end, "table terminator %#x != %#x" % (end, table_end)
    assert data[8:] == SCRIPT, "text must start at data + 8 and run to the end"


def main() -> int:
    check(0xFFFFFFFF)  # default: what the board's U-Boot needs
    check(0)  # what mkimage writes
    check(0x12345678)
    # the default really is 0xffffffff, and --table-end 0 differs from it only in the terminator and the two CRCs
    default = make_bootscr.make(SCRIPT, "x")
    plain = make_bootscr.make(SCRIPT, "x", 0)
    assert default[64 + 4:64 + 8] == b"\xff\xff\xff\xff" and plain[64 + 4:64 + 8] == b"\0\0\0\0", "terminator bytes"
    assert default[64 + 8:] == plain[64 + 8:] and len(default) == len(plain), "text and length differ"
    print("test-bootscr: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
