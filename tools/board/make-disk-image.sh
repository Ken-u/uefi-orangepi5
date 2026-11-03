#!/bin/bash
# Build host: turn the bundle into files that can be written to the NVMe drive from ANY machine with `dd`, for the case where the
# drive is not in a Linux machine but exported by U-Boot (`ums 0 nvme 0`) to a Mac.
#
#   tools/board/make-disk-image.sh                        # drive of 128035676160 bytes (the 128 GB drive of this plan)
#   DISK_BYTES=N tools/board/make-disk-image.sh           # another drive: N from `diskutil info` / blockdev --getsize64, 512-byte sectors
#
# It runs nvme-install.py (the same code that writes a real drive, with its read-back check) against a sparse file of the size of
# the drive, then cuts out what a write has to cover:
#   out/disk/head.img   from LBA 0 to the end of the root image: MBR, GPT, ESP, root image (about 9.65 GB)
#   out/disk/tail.img   the last 33 sectors: the backup GPT. Written at sector (DISK_BYTES / 512 - 33)
#   out/disk/esp.img    the ESP alone (256 MiB), for later updates: written at 1 MiB (LBA 2048)
#   out/disk/SHA256SUMS
# The rest of the drive is not written. The header of the Data window (1 MiB at LBA 130547712 = 63744 MiB on a 128 GB drive; the
# number is printed) has to be zero: write zeros there once, so the first boot formats it. docs/first-boot.md has the commands.
#
# Needs the bundle (make-bundle.sh) and about 20 GB free in out/. The sparse file is deleted at the end (KEEP_DISK=1 keeps it).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="${BUNDLE:-$ROOT/out/bundle}"
DISK_DIR="${DISK_DIR:-$ROOT/out/disk}"
DISK_BYTES="${DISK_BYTES:-128035676160}"
IMG="${IMG:-$ROOT/out/nvme-disk.img}"

[ -f "$BUNDLE/layout.json" ] || { echo "error: no bundle in $BUNDLE (tools/board/make-bundle.sh)" >&2; exit 1; }
[ $((DISK_BYTES % 512)) -eq 0 ] || { echo "error: DISK_BYTES is not a multiple of 512" >&2; exit 1; }

# first_lba of userdata, size of the root image, first block of the Data window: from the bundle, not retyped
read -r USERDATA_LBA ROOT_BYTES < <(python3 -c '
import json, sys
l = json.load(open(sys.argv[1] + "/layout.json"))
print(l["userdata"]["first_lba"], l["root"]["bytes"])' "$BUNDLE")
HEAD_BYTES=$((USERDATA_LBA * 512 + ROOT_BYTES))
TAIL_SECTORS=33
TOTAL_SECTORS=$((DISK_BYTES / 512))
mkdir -p "$DISK_DIR"
rm -f "$IMG"
truncate -s "$DISK_BYTES" "$IMG"

echo "== nvme-install.py into a sparse file of $DISK_BYTES bytes ($TOTAL_SECTORS sectors)"
python3 "$BUNDLE/nvme-install.py" "$BUNDLE" --device "$IMG" --write --expect-bytes "$DISK_BYTES" | grep -v '%' | tail -n 25

echo "== cutting out head.img ($HEAD_BYTES bytes), tail.img and esp.img"
head -c "$HEAD_BYTES" "$IMG" > "$DISK_DIR/head.img"
tail -c $((TAIL_SECTORS * 512)) "$IMG" > "$DISK_DIR/tail.img"
cp -fL --sparse=never "$BUNDLE/esp.img" "$DISK_DIR/esp.img"
[ "${KEEP_DISK:-0}" = 1 ] || rm -f "$IMG"
(cd "$DISK_DIR" && sha256sum head.img tail.img esp.img > SHA256SUMS && sed 's/^/   /' SHA256SUMS)

DATA_MIB=$(python3 -c '
import json, sys
l = json.load(open(sys.argv[1] + "/layout.json"))
print((l["userdata"]["last_lba"] + 1 - (l["data"]["header_mib"] + l["data"]["container_mib"]) * 2048) // 2048)' "$BUNDLE")
cat <<EOF

On the Mac (disk N is the drive U-Boot exports; \`diskutil unmountDisk /dev/diskN\` before EVERY dd, macOS mounts the ESP again each time):
  dd if=head.img of=/dev/rdiskN bs=4m
  dd if=tail.img of=/dev/rdiskN bs=512 seek=$((TOTAL_SECTORS - TAIL_SECTORS))
  dd if=/dev/zero of=/dev/rdiskN bs=1m count=1 seek=$DATA_MIB          # header of the Data window
Later, the ESP alone:
  dd if=esp.img of=/dev/rdiskN bs=1m seek=1
EOF
