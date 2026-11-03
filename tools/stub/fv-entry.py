#!/usr/bin/env python3
"""Print the entry point of a UEFI firmware volume (BL33_AP_UEFI.Fv) as an offset from the start of the volume.

    fv-entry.py BL33_AP_UEFI.Fv            prints 0x1400 (hexadecimal)
    fv-entry.py BL33_AP_UEFI.Fv --verbose  also says how it was found

Why: tools/stub/probe.S moves the volume to 0x200000 and jumps to 0x200000 + this offset, which is what TF-A does for BL33 in the
normal flash flow. The EVB10 stub had the offset written into the assembly (0x1400). Here it is read from the volume that is being
wrapped, so a different build of the firmware cannot leave the stub jumping into the middle of something else.

How: the first 16 bytes of an ARM firmware volume are the ZeroVector, and edk2 puts the reset vector there: a single AArch64
`B <imm26>` to the entry of the SEC module (PeilessSec). The offset is imm26 * 4 from the volume start. The EVB10 volume holds
`00 05 00 14` = 0x14000500 = B +0x1400, which is the 0x1400 its stub always used.
"""
import struct
import sys


def entry_offset(fv):
    if len(fv) < 0x30 or fv[0x28:0x2C] != b"_FVH":
        raise SystemExit("not a firmware volume (no _FVH signature at 0x28)")
    word = struct.unpack_from("<I", fv, 0)[0]
    if word & 0xFC000000 != 0x14000000:
        raise SystemExit("the first instruction of the volume is 0x%08x, not an AArch64 B: no reset vector to follow" % word)
    imm = word & 0x03FFFFFF
    if imm & 0x02000000:
        imm -= 0x04000000
    offset = imm * 4
    fv_length = struct.unpack_from("<Q", fv, 0x20)[0]
    if not 0x48 <= offset < min(fv_length, 0x10000):
        raise SystemExit("the reset vector branches to 0x%x, outside the first 64 KiB of the volume" % offset)
    return word, offset


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    with open(sys.argv[1], "rb") as handle:
        fv = handle.read(0x100)
    word, offset = entry_offset(fv)
    if "--verbose" in sys.argv[2:]:
        print("first instruction 0x%08x = B +0x%x" % (word, offset), file=sys.stderr)
    print("0x%x" % offset)
    return 0


if __name__ == "__main__":
    sys.exit(main())
