#!/bin/bash
# Capture the serial console of the Orange Pi 5 (UART2 on the 3-pin debug header, 1.5 Mbaud 8N1): the bytes as they came
# (runs/TAG.raw) and a copy with the elapsed seconds in front of every line (runs/TAG.ts).
#
#   tools/board/capture.sh TAG [SECONDS [DEVICE]]      defaults: 300 s, /dev/ttyUSB0
#
# Start it BEFORE the power goes on (the firmware's first lines come out within a second). One reader at a time: check
# `fuser /dev/ttyUSB0` first. A 3.3 V USB-serial adapter that supports 1500000 baud is needed (FT232H/FT232R and CP2102N do;
# a CH340 or PL2303 does not reliably); RX of the adapter to TX of the board, GND to GND, no 3.3 V.
#
# It records the whole time asked for, panics and watchdog resets included (the kernel restarts after a panic, debug=0x10014e, and the
# board then boots again). EXTRA_STOP is a regex that ends the capture 5 s after the first line that matches it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
TAG="${1:?usage: capture.sh TAG [SECONDS [DEVICE]]}"
SECS="${2:-300}"
DEV="${3:-/dev/ttyUSB0}"
CAP="$RK3588_BOARD_TOOLS/serial-capture.py"
[ -f "$CAP" ] || { echo "no $CAP (set RK3588_COMMON in .env)" >&2; exit 1; }
[ -c "$DEV" ] || { echo "no serial device $DEV" >&2; exit 1; }
if command -v fuser >/dev/null && fuser "$DEV" >/dev/null 2>&1; then
	echo "$DEV is in use by another process" >&2
	exit 1
fi
mkdir -p "$ROOT/runs"
stty -F "$DEV" 1500000 cs8 -cstopb -parenb raw -echo -echoe -echok -crtscts -ixon -ixoff
STOPS=()
[ -z "${EXTRA_STOP:-}" ] || STOPS=(--stop "$EXTRA_STOP" 5 "EXTRA_STOP matched")
echo "capturing $DEV for up to $SECS s -> $ROOT/runs/$TAG.{raw,ts}"
exec python3 "$CAP" ${STOPS[@]+"${STOPS[@]}"} "$DEV" "$SECS" "$ROOT/runs/$TAG.raw" "$ROOT/runs/$TAG.ts"
