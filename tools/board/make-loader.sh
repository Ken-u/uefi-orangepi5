#!/bin/bash
# Build machine: build the Maskrom loader (DDR init + USB plug + SPL) of the RK3588 from the rkbin blobs that edk2-rk3588 carries.
#
#   tools/board/make-loader.sh [OUTDIR]       # default out/bundle/maskrom
#
# Why: a PC in Maskrom mode (RKDevTool, `rkdeveloptool db <loader>`) needs this file before it can write the SPI NOR. It is the
# way back when the firmware does not come up and no Linux can start. The file is built with rkbin's own boot_merger from
# RKBOOT/RK3588MINIALL.ini, in a scratch directory (rkbin stays untouched).
#
# Not tested on a board: whether this loader is the one the Orange Pi 5 wants for SPI NOR is taken from the Radxa/Rockchip
# documentation (the same RK3588 loader family); docs/first-boot.md says how to try it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$ROOT/env.sh" ] && . "$ROOT/env.sh"
RKBIN="${RKBIN:-$ROOT/../edk2-rk3588/misc/rkbin}"
INI="${INI:-RKBOOT/RK3588MINIALL.ini}"
OUT="${1:-$ROOT/out/bundle/maskrom}"
[ -x "$RKBIN/tools/boot_merger" ] || { echo "error: no $RKBIN/tools/boot_merger (set RKBIN)" >&2; exit 1; }
[ -f "$RKBIN/$INI" ] || { echo "error: no $RKBIN/$INI" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/RKBOOT"
cp "$RKBIN/$INI" "$WORK/$INI"
# Every Path/FlashData/FlashBoot entry of the ini names a file below rkbin; copy exactly those.
sed -n 's/^\(Path[0-9]*\|FlashData\|FlashBoot\)=//p' "$RKBIN/$INI" | tr -d '\r' | while read -r f; do
	[ -f "$RKBIN/$f" ] || { echo "error: $f (named by $INI) is missing from $RKBIN" >&2; exit 1; }
	mkdir -p "$WORK/$(dirname "$f")"
	cp "$RKBIN/$f" "$WORK/$f"
done
(cd "$WORK" && "$RKBIN/tools/boot_merger" "$INI" 2>&1 | sed 's/^/   /')

NAME="$(sed -n 's/^PATH=//p' "$WORK/$INI" | tr -d '\r')"
[ -f "$WORK/$NAME" ] || { echo "error: boot_merger wrote no $NAME" >&2; exit 1; }
mkdir -p "$OUT"
cp "$WORK/$NAME" "$OUT/$NAME"
( cd "$OUT" && sha256sum "$NAME" | tee "$NAME.sha256" )
echo "loader: $OUT/$NAME ($(stat -c %s "$OUT/$NAME") bytes)"
