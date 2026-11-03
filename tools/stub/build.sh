#!/bin/bash
# Wrap the launcher firmware volume into an arm64 Linux Image that U-Boot starts with `booti`.
#
#   tools/stub/build.sh                     # the volume from `./build.sh -L` (out/launcher/)
#   FV=/path/to/volume.Fv tools/stub/build.sh
#   LAUNCHER_WDT=0 tools/stub/build.sh      # do not arm the hardware watchdog before the firmware
#
# Output: out/launcher/uefi-launcher.img. The offset of the firmware's entry point is read from the volume (fv-entry.py).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
OUT="${OUT:-$ROOT/out/launcher}"
FV="${FV:-$OUT/BL33_AP_UEFI-orangepi5-launcher.Fv}"
CLANG="${CLANG:-${CLANG_BIN:?set CLANG_BIN in .env}/clang}"
OBJCOPY="${OBJCOPY:-$(dirname "$CLANG")/llvm-objcopy}"
WDT="${LAUNCHER_WDT:-1}"

[ -f "$FV" ] || { echo "error: no firmware volume: $FV (run ./build.sh -L first)" >&2; exit 1; }
[ -x "$CLANG" ] || { echo "error: no clang: $CLANG" >&2; exit 1; }
size=$(stat -L -c %s "$FV")
[ "$size" -eq $((5 * 1024 * 1024)) ] || { echo "error: the volume is $size bytes, the stub and its linker script expect 5 MiB" >&2; exit 1; }

ENTRY="$(python3 "$HERE/fv-entry.py" "$FV" --verbose)"

mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$FV" "$work/fv.bin"
cd "$work"
"$CLANG" --target=aarch64-none-elf \
	-O2 -ffreestanding -nostdlib -fno-pic -fno-stack-protector \
	-mgeneral-regs-only -mstrict-align -Wall -Wextra \
	-DLAUNCHER_WDT="$WDT" -DFV_ENTRY_OFFSET="$ENTRY" \
	-c "$HERE/launcher.S" -o launcher.o
"$CLANG" --target=aarch64-none-elf -nostdlib -fuse-ld=lld \
	-T "$HERE/launcher.ld" -Wl,--build-id=none -Wl,-N \
	-o launcher.elf launcher.o
"$OBJCOPY" -O binary launcher.elf "$OUT/uefi-launcher.img"

echo "== entry 0x200000 + $ENTRY, LAUNCHER_WDT=$WDT"
echo "== $OUT/uefi-launcher.img: $(stat -c %s "$OUT/uefi-launcher.img") bytes"
xxd -l 64 "$OUT/uefi-launcher.img"
