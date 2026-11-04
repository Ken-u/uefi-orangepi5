#!/bin/bash
# Replace one file of the ESP from the U-Boot prompt of the board (nobody at the board, no Mac): the file goes into RAM over the serial
# console (YMODEM), then U-Boot writes it to the FAT volume of the NVMe drive and reads it back for a crc32.
#
#   tools/board/esp-put.sh [--dry-run] LOCALFILE ESPPATH
#   tools/board/esp-put.sh out/bundle/esp-files/EFI/UniXNU/unixnu.toml EFI/UniXNU/unixnu.toml
#   tools/board/esp-put.sh out/bundle/esp-files/EFI/UniXNU/Payloads/kernel.macho EFI/UniXNU/Payloads/kernel.macho     # about 20 minutes
#
# The board must sit at the U-Boot prompt (docs/first-boot.md section 9: capture with --send 'U-Boot v' ctrl-c...). Nothing else may
# read the serial device. The result line says VERIFIED (size and crc32 agree after the read back) or MISMATCH.
#
# Where the data goes (observed: evidence/device-memory-20261103.txt of UniXNU-orangepi5): RAM 0x8400000-0x9400000 is reserved (the trusted
# firmware's). Reading it from U-Boot is a Data Abort and U-Boot then hangs in "Please RESET the board": only pulling the plug helps. So the
# file is loaded at 0x1000000 (room for 116 MiB), in pieces of 16 MiB, and read back at 0xa000000, above the reserved range. The script
# refuses a file that would reach it. ESP_PUT_AVOID (START-END, default 0x8400000-0x9400000) names the range for another board.
#
# A piece of 16 MiB takes about 4 minutes (60-70 KB/s). After a transfer U-Boot needs about a minute before it takes the next `loady`:
# the script polls the prompt with `echo hi` first, and a piece that fails is sent again (3 tries).
#
# Needs .env: BOARD_HOST (ssh target) and BOARD_SERIAL_DEV (by-id path); uboot-put.py and uboot-cmd.py come from UniXNU-rk3588-common.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
F="${1:?usage: esp-put.sh [--dry-run] LOCALFILE ESPPATH}"
P="${2:?usage: esp-put.sh [--dry-run] LOCALFILE ESPPATH}"
[ -f "$F" ] || { echo "no file $F" >&2; exit 1; }
HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
DEV="${BOARD_SERIAL_DEV:-/dev/ttyUSB0}"
AVOID="${ESP_PUT_AVOID:-0x8400000-0x9400000}"
BASE=$((0x1000000))
PIECE=$((0x1000000))
VERIFY=$((0xa000000))
AVOID_START=$((${AVOID%-*})); AVOID_END=$((${AVOID#*-}))

SZ=$(stat -c %s "$F")
[ "$SZ" -gt 0 ] || { echo "$F is empty" >&2; exit 1; }
CRC=$(python3 -c "import zlib,sys;print('%08x'%(zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff))" "$F")
overlaps() { [ "$1" -lt "$AVOID_END" ] && [ $(($1 + $2)) -gt "$AVOID_START" ]; }
if overlaps "$BASE" "$SZ"; then
	echo "refused: $SZ bytes at $(printf 0x%x $BASE) reach the reserved range $AVOID (U-Boot would hang)" >&2; exit 1
fi
if overlaps "$VERIFY" "$SZ"; then
	echo "refused: the read back of $SZ bytes at $(printf 0x%x $VERIFY) would reach the reserved range $AVOID" >&2; exit 1
fi
PIECES=$(( (SZ + PIECE - 1) / PIECE ))
echo "$F -> $P: $SZ bytes, crc32 $CRC, $PIECES piece(s) of up to $PIECE bytes at $(printf 0x%x $BASE).., read back at $(printf 0x%x $VERIFY)"
if [ "$DRY" = 1 ]; then
	for ((i = 0; i < PIECES; i++)); do
		off=$((i * PIECE)); len=$((SZ - off)); [ "$len" -gt "$PIECE" ] && len=$PIECE
		echo "  piece $i: file offset $off, $len bytes, RAM $(printf 0x%x $((BASE + off))) - $(printf 0x%x $((BASE + off + len)))"
	done
	echo "  fatwrite nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ); fatload nvme 0:1 $(printf 0x%x $VERIFY) $P; crc32 $(printf 0x%x $VERIFY) $(printf 0x%x $SZ)"
	exit 0
fi

TOOLS="$RK3588_BOARD_TOOLS"
[ -f "$TOOLS/uboot-put.py" ] && [ -f "$TOOLS/uboot-cmd.py" ] || { echo "no uboot-put.py / uboot-cmd.py in $TOOLS (set RK3588_COMMON in .env)" >&2; exit 1; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")
ENVSET="export SERIAL_DEV='$DEV';"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"${SSH[@]}" "mkdir -p ~/unixnu-opi5/esp-put && find ~/unixnu-opi5/esp-put -maxdepth 1 -name 'piece.*' -delete"
scp -q -o BatchMode=yes "$TOOLS/uboot-put.py" "$TOOLS/uboot-cmd.py" "$HOST:unixnu-opi5/"
split -b "$PIECE" -d -a 3 "$F" "$TMP/piece."
scp -q -o BatchMode=yes "$TMP"/piece.* "$HOST:unixnu-opi5/esp-put/"

prompt() { # wait until U-Boot answers `echo hi` (the receiver of the last transfer needs about a minute)
	local o
	for _ in $(seq 1 12); do
		o=$("${SSH[@]}" "$ENVSET TO=8 timeout 30 python3 ~/unixnu-opi5/uboot-cmd.py 'echo hi' 2>&1 | tail -2" || true)
		echo "$o" | grep -q '^hi' && return 0
		sleep 15
	done
	return 1
}

i=0
for piece in "$TMP"/piece.*; do
	n=$(basename "$piece"); addr=$((BASE + i * PIECE)); ok=0
	for attempt in 1 2 3; do
		prompt || { echo "no U-Boot prompt on $DEV (is the board at the U-Boot prompt?)" >&2; exit 1; }
		echo "$(date +%T) piece $i/$PIECES at $(printf 0x%x $addr) (try $attempt)"
		if "${SSH[@]}" "$ENVSET timeout 1200 python3 ~/unixnu-opi5/uboot-put.py --avoid $AVOID ~/unixnu-opi5/esp-put/$n $(printf 0x%x $addr) 2>&1 | tail -3" \
			| tee "$TMP/out" | tail -1; grep -q "uboot-put: ok" "$TMP/out"; then ok=1; break; fi
	done
	[ "$ok" = 1 ] || { echo "piece $i failed three times" >&2; exit 1; }
	i=$((i + 1))
done
prompt || { echo "no U-Boot prompt before the write" >&2; exit 1; }
echo "$(date +%T) fatwrite and read back"
"${SSH[@]}" "$ENVSET TO=300 python3 ~/unixnu-opi5/uboot-cmd.py 'nvme scan' 'fatwrite nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ)' 'fatload nvme 0:1 $(printf 0x%x $VERIFY) $P' 'crc32 $(printf 0x%x $VERIFY) $(printf 0x%x $SZ)'" | tee "$TMP/cmd"
if grep -q "^$SZ bytes read" "$TMP/cmd" && grep -q "==> $CRC" "$TMP/cmd"; then
	echo "VERIFIED $P $SZ bytes crc32 $CRC"
else
	echo "MISMATCH $P (want $SZ bytes, crc32 $CRC)"; exit 1
fi
