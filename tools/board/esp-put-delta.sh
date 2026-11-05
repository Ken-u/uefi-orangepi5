#!/bin/bash
# esp-put.sh for a file that is already on the ESP in an older version: only the 1 MiB blocks that differ cross the serial line.
#
#   tools/board/esp-put-delta.sh [--dry-run] LOCALFILE ESPPATH
#   tools/board/esp-put-delta.sh out/bundle/esp-files/EFI/UniXNU/Payloads/kernel.macho EFI/UniXNU/Payloads/kernel.macho
#
# How: U-Boot reads the file that is on the ESP now into RAM (fatload from the NVMe drive: a second), takes the crc32 of every
# 1 MiB block and the script compares them with the blocks of LOCALFILE. Differing blocks are sent (YMODEM, 60-70 KB/s, so 1 MiB is
# about 16 s) into the same place in RAM; blocks that differ and lie at most MERGE_GAP blocks apart go in one transfer, because after
# each transfer U-Boot needs about a minute before it takes the next `loady`. Then, as esp-put.sh does, the whole file is written to
# the FAT volume, read back at 0xa000000 and compared by crc32 (VERIFIED / MISMATCH). A kernel rebuilt after a small driver change
# has the same size and differs in a few places; with no older file on the ESP every block differs and this is esp-put.sh with
# 1 MiB granularity (use esp-put.sh then).
#
# Same rules as esp-put.sh (board at the U-Boot prompt, nobody else on the serial device, RAM 0x8400000-0x9400000 is never touched).
# Needs .env: BOARD_HOST, BOARD_SERIAL_DEV; uboot-put.py and uboot-cmd.py come from UniXNU-rk3588-common.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
F="${1:?usage: esp-put-delta.sh [--dry-run] LOCALFILE ESPPATH}"
P="${2:?usage: esp-put-delta.sh [--dry-run] LOCALFILE ESPPATH}"
[ -f "$F" ] || { echo "no file $F" >&2; exit 1; }
HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
DEV="${BOARD_SERIAL_DEV:-/dev/ttyUSB0}"
AVOID="${ESP_PUT_AVOID:-0x8400000-0x9400000}"
MERGE_GAP="${MERGE_GAP:-3}"
BASE=$((0x1000000))
BLK=$((0x100000))
MAXPIECE=$((0x1000000))
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
NBLK=$(( (SZ + BLK - 1) / BLK ))
echo "$F -> $P: $SZ bytes, crc32 $CRC, $NBLK block(s) of $BLK bytes at $(printf 0x%x $BASE)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# crc32 of every block of the local file, one "ADDRESS CRC" line each (U-Boot prints the address as 8 hex digits)
python3 - "$F" "$BASE" "$BLK" > "$TMP/local.crc" <<'PY'
import sys, zlib
path, base, blk = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, 'rb') as f:
    i = 0
    while True:
        d = f.read(blk)
        if not d:
            break
        print('%08x %08x %d' % (base + i * blk, zlib.crc32(d) & 0xffffffff, len(d)))
        i += 1
PY
CRCCMDS=()
while read -r addr _ len; do CRCCMDS+=("crc32 0x$addr $(printf 0x%x "$len")"); done < "$TMP/local.crc"
if [ "$DRY" = 1 ]; then
	echo "  fatload nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ); ${#CRCCMDS[@]} x crc32 (first: ${CRCCMDS[0]}); send the blocks that differ;"
	echo "  fatwrite nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ); fatload nvme 0:1 $(printf 0x%x $VERIFY) $P; crc32 $(printf 0x%x $VERIFY) $(printf 0x%x $SZ)"
	exit 0
fi

TOOLS="$RK3588_BOARD_TOOLS"
[ -f "$TOOLS/uboot-put.py" ] && [ -f "$TOOLS/uboot-cmd.py" ] || { echo "no uboot-put.py / uboot-cmd.py in $TOOLS (set RK3588_COMMON in .env)" >&2; exit 1; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")
ENVSET="export SERIAL_DEV='$DEV';"
"${SSH[@]}" "mkdir -p ~/unixnu-opi5/esp-put && find ~/unixnu-opi5/esp-put -maxdepth 1 -name 'piece.*' -delete"
scp -q -o BatchMode=yes "$TOOLS/uboot-put.py" "$TOOLS/uboot-cmd.py" "$HOST:unixnu-opi5/"

prompt() { # wait until U-Boot answers `echo hi` (the receiver of the last transfer needs about a minute)
	local o
	for _ in $(seq 1 12); do
		o=$("${SSH[@]}" "$ENVSET TO=8 timeout 30 python3 ~/unixnu-opi5/uboot-cmd.py 'echo hi' 2>&1 | tail -2" || true)
		echo "$o" | grep -q '^hi' && return 0
		sleep 15
	done
	return 1
}

prompt || { echo "no U-Boot prompt on $DEV (is the board at the U-Boot prompt?)" >&2; exit 1; }
echo "$(date +%T) reading the file on the ESP into RAM and taking the crc32 of every block"
# fatload reads at most SZ bytes (never past the range checked above). A missing file just leaves stale RAM: every block then differs.
# The commands are quoted for the board host's shell by printf %q.
QUOTED=""; for c in "nvme scan" "fatload nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ)" "${CRCCMDS[@]}"; do QUOTED+=" $(printf %q "$c")"; done
"${SSH[@]}" "$ENVSET TO=60 python3 ~/unixnu-opi5/uboot-cmd.py $QUOTED" > "$TMP/remote.out" || true
python3 - "$TMP/local.crc" "$TMP/remote.out" "$MERGE_GAP" "$MAXPIECE" "$BLK" "$BASE" > "$TMP/plan" <<'PY'
import re, sys
local = [l.split() for l in open(sys.argv[1])]
remote = {}
for m in re.finditer(r'crc32 for ([0-9a-f]{8}) \.\.\. [0-9a-f]{8} ==> ([0-9a-f]{8})', open(sys.argv[2], errors='replace').read()):
    remote[m.group(1)] = m.group(2)
gap, maxpiece, blk, base = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
diff = [i for i, (a, c, _) in enumerate(local) if remote.get(a) != c]
print('# %d of %d blocks differ (%d crc32 answers read)' % (len(diff), len(local), len(remote)))
runs = []
for i in diff:
    if runs and i - runs[-1][1] <= gap + 1:
        runs[-1][1] = i
    else:
        runs.append([i, i])
per = maxpiece // blk
for a, b in runs:
    while a <= b:
        e = min(b, a + per - 1)
        print('%d %d' % (a, e))
        a = e + 1
PY
head -1 "$TMP/plan"
mapfile -t RUNS < <(tail -n +2 "$TMP/plan")
SENT=0
for r in "${RUNS[@]}"; do
	a=${r% *}; b=${r#* }
	off=$((a * BLK)); len=$(( (b - a + 1) * BLK )); [ $((off + len)) -gt "$SZ" ] && len=$((SZ - off))
	addr=$((BASE + off)); ok=0
	dd if="$F" of="$TMP/piece.$a" bs="$BLK" skip="$a" count=$((b - a + 1)) status=none
	scp -q -o BatchMode=yes "$TMP/piece.$a" "$HOST:unixnu-opi5/esp-put/piece.$a"
	for attempt in 1 2 3; do
		prompt || { echo "no U-Boot prompt on $DEV" >&2; exit 1; }
		echo "$(date +%T) blocks $a-$b ($len bytes) at $(printf 0x%x $addr) (try $attempt)"
		if "${SSH[@]}" "$ENVSET timeout 1200 python3 ~/unixnu-opi5/uboot-put.py --avoid $AVOID ~/unixnu-opi5/esp-put/piece.$a $(printf 0x%x $addr) 2>&1 | tail -3" \
			| tee "$TMP/out" | tail -1; grep -q "uboot-put: ok" "$TMP/out"; then ok=1; break; fi
	done
	[ "$ok" = 1 ] || { echo "blocks $a-$b failed three times" >&2; exit 1; }
	SENT=$((SENT + len))
done
echo "sent $SENT bytes of $SZ"
prompt || { echo "no U-Boot prompt before the write" >&2; exit 1; }
echo "$(date +%T) fatwrite and read back"
"${SSH[@]}" "$ENVSET TO=300 python3 ~/unixnu-opi5/uboot-cmd.py 'nvme scan' 'fatwrite nvme 0:1 $(printf 0x%x $BASE) $P $(printf 0x%x $SZ)' 'fatload nvme 0:1 $(printf 0x%x $VERIFY) $P' 'crc32 $(printf 0x%x $VERIFY) $(printf 0x%x $SZ)'" | tee "$TMP/cmd"
if grep -q "^$SZ bytes read" "$TMP/cmd" && grep -q "==> $CRC" "$TMP/cmd"; then
	echo "VERIFIED $P $SZ bytes crc32 $CRC (sent $SENT)"
else
	echo "MISMATCH $P (want $SZ bytes, crc32 $CRC)"; exit 1
fi
