#!/bin/bash
# Restarts a running UniXNU kernel from the board host's serial line: the kernel's wdt-kick thread (NativeNvme.cpp) counts Ctrl-C bytes
# and calls PSCI SYSTEM_RESET after three within two seconds. The kernel's own console reader takes some of the bytes, so a burst is sent:
# thirty, 0.1 s apart. Run it while a capture is open (capture-remote.sh with the U-Boot banner rule) to land at the U-Boot prompt.
#   console-reset.sh [COUNT]
cd "$(dirname "$0")/../.." || exit 1
set -a; . ./.env; set +a
ssh -o BatchMode=yes "$BOARD_HOST" "for i in \$(seq 1 ${1:-30}); do printf '\\003' > $BOARD_SERIAL_DEV; sleep 0.1; done"
