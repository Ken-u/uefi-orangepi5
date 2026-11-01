#!/bin/bash
# Capture the serial console of the Orange Pi 5 on the board host (the machine the USB serial adapter is plugged into) and
# bring the log back: runs/TAG.raw (as received) and runs/TAG.ts (with the elapsed seconds in front of every line).
#
#   tools/board/capture-remote.sh TAG [SECONDS [DEVICE]]      defaults: 300 s, /dev/ttyUSB0
#
# BOARD_HOST (ssh target, key authentication) comes from .env. Start it BEFORE the power goes on; it blocks for SECONDS.
# Needs python3 and stty on the board host; serial-capture.py is copied there (~/unixnu-opi5). One reader at a time:
# it refuses when something else has the device open (another capture, the EVB10's run-kernel.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
TAG="${1:?usage: capture-remote.sh TAG [SECONDS [DEVICE]]}"
SECS="${2:-300}"
DEV="${3:-/dev/ttyUSB0}"
CAP="$RK3588_BOARD_TOOLS/serial-capture.py"
[ -f "$CAP" ] || { echo "no $CAP (set RK3588_COMMON in .env)" >&2; exit 1; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

"${SSH[@]}" "mkdir -p ~/unixnu-opi5/runs && test -c '$DEV'" || { echo "no $DEV on the board host" >&2; exit 1; }
if "${SSH[@]}" "fuser '$DEV' >/dev/null 2>&1"; then
	echo "$DEV is in use on the board host:" >&2
	"${SSH[@]}" "fuser -v '$DEV' 2>&1" >&2 || true
	exit 1
fi
scp -q -o BatchMode=yes "$CAP" "$HOST:unixnu-opi5/serial-capture.py"
mkdir -p "$ROOT/runs"
echo "capturing $DEV on the board host for up to $SECS s (tag $TAG); power the board on now"
"${SSH[@]}" "stty -F '$DEV' 1500000 cs8 -cstopb -parenb raw -echo -echoe -echok -crtscts -ixon -ixoff && \
	python3 ~/unixnu-opi5/serial-capture.py '$DEV' '$SECS' ~/unixnu-opi5/runs/$TAG.raw ~/unixnu-opi5/runs/$TAG.ts" || true
scp -q -o BatchMode=yes "$HOST:unixnu-opi5/runs/$TAG.raw" "$HOST:unixnu-opi5/runs/$TAG.ts" "$ROOT/runs/"
echo "-> $ROOT/runs/$TAG.ts ($(wc -l < "$ROOT/runs/$TAG.ts") lines), $ROOT/runs/$TAG.raw ($(stat -c %s "$ROOT/runs/$TAG.raw") bytes)"
