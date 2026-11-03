#!/bin/bash
# Build machine: (rebuild the payload,) take the shutdown entry out of it, and collect everything the board needs into out/bundle.
#
#   tools/board/make-bundle.sh                       # from the payload that exists
#   REBUILD=1 tools/board/make-bundle.sh             # run `unixnu build payload` first (about half a minute)
#   REBUILD=1 EXTRA_KERNEL_ARGS="nvme=1 wdt-kick=330" tools/board/make-bundle.sh
#
# DEFAULT_ENTRY / MENU_TIMEOUT: the menu entry that starts by itself and after how many seconds (default xnu-probe, 10).
# EXTRA_KERNEL_ARGS (NAME=VALUE, space separated) replaces or adds boot arguments for this payload only; board.toml stays as it is.
# Examples: nvme=1 (probe the drive, publish nothing), nvme-probe=4096, nvme-data-reset=1, nvme-data-persist=0 (Data in RAM), vc_mirror=1.
#
# The ESP also gets the launcher (uefi-launcher.img: stub plus the firmware volume from `./build.sh -L`, and boot.scr that starts it
# from U-Boot), when out/launcher/BL33_AP_UEFI-orangepi5-launcher.Fv exists. out/disk/esp.img is the same ESP as a file of its own
# for updating the ESP alone through U-Boot's `ums` (docs/first-boot.md).
#
# Needs (.env): UNIXNU, DEVICE_DIR, UNIQUE_CHIP_ID, ARTIFACTS, ROOT_IMAGE; UNIXNU_WRAP, MTOOLS_BIN, JOBS as the machine needs them.
# The kernel must be built first (UniXNU-orangepi5/scripts/build-orangepi5-kernel.sh); the firmware image (./build.sh) is optional.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
UNIXNU="${UNIXNU:?set UNIXNU in .env}"
DEVICE="${DEVICE_DIR:?set DEVICE_DIR (the UniXNU-orangepi5 checkout) in .env}"
ART="${ARTIFACTS:?set ARTIFACTS in .env}"
ROOT_IMAGE="${ROOT_IMAGE:?set ROOT_IMAGE (userdata-root.img) in .env}"
PAYLOAD="${PAYLOAD:-$UNIXNU/out/orangepi5/ipados-17.7.11-21H461/orangepi5/payload/payload.img}"
NOR="${NOR:-$ROOT/out/RK3588_NOR_FLASH-unixnu-orangepi5.img}"
OUT="${OUT:-$ROOT/out/bundle}"
LAUNCHER_DIR="${LAUNCHER_DIR:-$ROOT/out/launcher}"
DISK_DIR="${DISK_DIR:-$ROOT/out/disk}"
TRUST_CACHE="${TRUST_CACHE-$ART/trust/original-static-system.bundle}"
DATA_MIB="${DATA_MIB:-2048}"
# The menu starts DEFAULT_ENTRY after MENU_TIMEOUT seconds. The default is the probe (reads the drive, writes nothing) with time to read
# the screen: a missed key must not start the normal boot on a board that has never run. Once the log is good: DEFAULT_ENTRY=xnu MENU_TIMEOUT=3.
DEFAULT_ENTRY="${DEFAULT_ENTRY:-xnu-probe}"
MENU_TIMEOUT="${MENU_TIMEOUT:-10}"
DATA_SEED="${DATA_SEED-$ART/data/owner-data-$DATA_MIB.trim.img}"

if [ "${REBUILD:-0}" = 1 ]; then
	echo "== payload"
	ARGS=""
	if [ -n "$TRUST_CACHE" ]; then
		[ -f "$TRUST_CACHE" ] || { echo "error: no trust cache bundle $TRUST_CACHE" >&2; exit 1; }
		ARGS="$ARGS --trust-cache $TRUST_CACHE"
		echo "   trust cache: $TRUST_CACHE (sha256 $(sha256sum "$TRUST_CACHE" | cut -c1-16)...)"
	fi
	if [ -n "$DATA_SEED" ]; then
		[ -f "$DATA_SEED" ] || { echo "error: no Data seed $DATA_SEED" >&2; exit 1; }
		ARGS="$ARGS --data-ramdisk $DATA_SEED"
		echo "   Data seed: $DATA_SEED ($(stat -c %s "$DATA_SEED") bytes, sha256 $(sha256sum "$DATA_SEED" | cut -c1-16)...)"
	fi
	for kernel_arg in ${EXTRA_KERNEL_ARGS:-}; do
		ARGS="$ARGS --kernel-arg $kernel_arg"
		echo "   extra kernel argument: $kernel_arg"
	done
	(cd "$UNIXNU" && ${UNIXNU_WRAP:-} bash -c \
		'./unixnu build payload -D "'"$DEVICE"'" --unique-chip-id "'"${UNIQUE_CHIP_ID:?set UNIQUE_CHIP_ID in .env}"'"'"$ARGS"' -j "'"${JOBS:-8}"'"')
fi

[ -f "$PAYLOAD" ] || { echo "error: no payload $PAYLOAD (REBUILD=1 builds it)" >&2; exit 1; }
echo "== the payload's menu: no power-off entry, default entry $DEFAULT_ENTRY, countdown $MENU_TIMEOUT s"
python3 "$HERE/patch-payload-toml.py" "$PAYLOAD" --default "$DEFAULT_ENTRY" --timeout "$MENU_TIMEOUT"
python3 "$HERE/patch-payload-toml.py" "$PAYLOAD" --default "$DEFAULT_ENTRY" --timeout "$MENU_TIMEOUT" --check

MCOPY="${MTOOLS_BIN:+$MTOOLS_BIN/}mcopy"
if [ -f "$LAUNCHER_DIR/BL33_AP_UEFI-orangepi5-launcher.Fv" ]; then
	echo "== launcher: uefi-launcher.img and boot.scr into the ESP (U-Boot starts the firmware from the NVMe, nothing is flashed)"
	"$ROOT/tools/stub/build.sh" | sed -n '1,3p'
	python3 "$HERE/make-bootscr.py" "$HERE/boot.cmd" "$LAUNCHER_DIR/boot.scr"
	"$MCOPY" -o -i "$PAYLOAD" "$LAUNCHER_DIR/uefi-launcher.img" "$LAUNCHER_DIR/boot.scr" ::/
	mkdir -p "$OUT/uboot"
	cp -f "$LAUNCHER_DIR/uefi-launcher.img" "$LAUNCHER_DIR/boot.scr" "$HERE/boot.cmd" "$OUT/uboot/"
	echo "   $(stat -c %s "$LAUNCHER_DIR/uefi-launcher.img") bytes uefi-launcher.img, $(stat -c %s "$LAUNCHER_DIR/boot.scr") bytes boot.scr"
else
	echo "== launcher: none ($LAUNCHER_DIR has no firmware volume; ./build.sh -L builds it). The ESP will not start from U-Boot."
fi
echo "== bundle"
NOR_ARG=()
if [ -f "$NOR" ]; then NOR_ARG=(--nor "$NOR"); else echo "   (no firmware image $NOR: the bundle has no nor.img)"; fi
python3 "$HERE/make-bundle.py" "$OUT" --device-repo "$DEVICE" --payload "$PAYLOAD" --root "$ROOT_IMAGE" ${NOR_ARG[@]+"${NOR_ARG[@]}"}
echo "== the ESP alone, for an update through U-Boot's ums"
mkdir -p "$DISK_DIR"
cp -f --sparse=never "$PAYLOAD" "$DISK_DIR/esp.img"
(cd "$DISK_DIR" && { grep -v ' esp\.img$' SHA256SUMS 2>/dev/null || true; sha256sum esp.img; } > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS && sed 's/^/   /' SHA256SUMS)
echo "== the payload's files for a USB stick (updating the ESP from the UEFI shell, no Linux needed)"
rm -rf "$OUT/esp-files"
mkdir -p "$OUT/esp-files"
"${MTOOLS_BIN:+$MTOOLS_BIN/}mcopy" -s -p -i "$PAYLOAD" ::/EFI "$OUT/esp-files/"
(cd "$OUT/esp-files" && find . -type f | sort | while read -r f; do printf '   %s  %s\n' "$(stat -c %s "$f")" "$f"; done)
echo "== Maskrom loader (the way back from a PC when the firmware does not come up)"
"$HERE/make-loader.sh" "$OUT/maskrom" || echo "   (no loader: Maskrom recovery needs one, see docs/first-boot.md)"
echo "== kernel arguments of this payload:"
M="${MTOOLS_BIN:+$MTOOLS_BIN/}mtype"
"$M" -i "$PAYLOAD" ::/EFI/UniXNU/unixnu.toml | sed -n 's/^args = /   /p'
echo
echo "To the board (Linux, as root there):"
echo "  rsync -aL --partial --info=progress2 $OUT/ BOARD:~/unixnu-bundle/"
echo "  ssh BOARD 'cd ~/unixnu-bundle && sudo python3 nvme-install.py . --device /dev/nvme0n1'      # dry run first"
