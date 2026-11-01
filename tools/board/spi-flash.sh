#!/bin/bash
# Board side: Linux on the Orange Pi 5, as root. Writes the UniXNU firmware (nor.img of the bundle) to the SPI NOR flash,
# after saving what is in the flash now.
#
#   ./spi-flash.sh BUNDLE                 dry run: finds the flash, checks the image, says what it would do
#   WRITE=1 ./spi-flash.sh BUNDLE         backup to BACKUP_DIR (default: BUNDLE/../spi-backup), erase + write + compare
#
#   MTD=/dev/mtdN                         use this device when more than one looks like the flash
#   BACKUP_DIR=DIR                        where the backup of the old flash content goes
#
# Why a backup: the flash holds whatever boots the board now (the vendor's U-Boot). If the new firmware does not come up, that content,
# written back the same way (`flashcp -v BACKUP /dev/mtdN`), restores the old boot; otherwise the way back is Maskrom mode
# (docs/first-boot.md).
#
# What it needs: `flashcp` (apt install mtd-utils). It does not fall back to writing /dev/mtdblock0, which erases blindly.
set -euo pipefail

BUNDLE="${1:?usage: spi-flash.sh BUNDLE}"
IMG="$BUNDLE/nor.img"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$BUNDLE/.." && pwd)/spi-backup}"
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { say "refusing: $*"; exit 1; }

[ -f "$IMG" ] || die "no $IMG"
[ "$(id -u)" = 0 ] || [ "${WRITE:-0}" != 1 ] || die "writing needs root"
SIZE=$(stat -c %s "$IMG")
WANT=$(awk -v f=nor.img '$2 == f {print $1}' "$BUNDLE/SHA256SUMS")
[ -n "$WANT" ] || die "SHA256SUMS has no line for nor.img"
HAVE=$(sha256sum "$IMG" | cut -d' ' -f1)
[ "$HAVE" = "$WANT" ] || die "nor.img has sha256 $HAVE, SHA256SUMS says $WANT"
say "image: $IMG, $SIZE bytes, sha256 ${HAVE:0:16}..."

PROC_MTD="${PROC_MTD:-/proc/mtd}"
[ -r "$PROC_MTD" ] || die "no $PROC_MTD: the kernel has no MTD support or the flash is not enabled (use Maskrom, docs/first-boot.md)"
say "$PROC_MTD:"
sed 's/^/    /' "$PROC_MTD"
if [ -n "${MTD:-}" ]; then
	NODE="$MTD"
else
	CANDIDATES=$(awk -F'[: ]+' '/^mtd[0-9]+:/ && tolower($0) ~ /nor|spi|sfc|fspi/ {print "/dev/" $1}' "$PROC_MTD")
	[ -n "$CANDIDATES" ] || die "no SPI NOR flash in /proc/mtd (the board's device tree may not enable it; use Maskrom, docs/first-boot.md)"
	[ "$(echo "$CANDIDATES" | wc -l)" = 1 ] || die "more than one candidate ($(echo $CANDIDATES)); pick one with MTD=/dev/mtdN"
	NODE="$CANDIDATES"
fi
[ -c "$NODE" ] || die "$NODE is not a character device"
NAME=$(basename "$NODE")
FLASH=$(( 0x$(awk -v n="$NAME:" '$1 == n {print $2}' "$PROC_MTD") ))
ERASE=$(( 0x$(awk -v n="$NAME:" '$1 == n {print $3}' "$PROC_MTD") ))
say "flash: $NODE, $FLASH bytes, erase block $ERASE"
[ "$FLASH" -ge "$SIZE" ] || die "the flash ($FLASH bytes) is smaller than the image ($SIZE)"
[ "$FLASH" -le $((64 << 20)) ] || die "$NODE is $FLASH bytes: not an SPI NOR flash of an Orange Pi 5 (16 MiB)"
command -v flashcp >/dev/null || die "flashcp is missing: apt install mtd-utils"

if [ "${WRITE:-0}" != 1 ]; then
	say "dry run: would save the $FLASH bytes of $NODE to $BACKUP_DIR, then run flashcp -v $IMG $NODE and compare. To do it: WRITE=1"
	exit 0
fi

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/spi-$(date +%Y%m%d-%H%M%S).bin"
say "backup -> $BACKUP"
dd if="$NODE" of="$BACKUP" bs=64k status=none
[ "$(stat -c %s "$BACKUP")" = "$FLASH" ] || die "the backup has the wrong size"
sha256sum "$BACKUP" | tee "$BACKUP.sha256"
say "writing (flashcp erases, writes and compares)"
flashcp -v "$IMG" "$NODE"
say "comparing again through a plain read"
cmp -n "$SIZE" "$IMG" "$NODE" || die "the flash differs from the image after writing"
say "OK: $NODE holds nor.img ($SIZE bytes). The backup of the old content: $BACKUP (keep it off the board)."
