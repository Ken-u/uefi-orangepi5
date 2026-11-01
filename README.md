# uefi-orangepi5

UEFI firmware platform for the **Orange Pi 5** (Rockchip RK3588S) that boots UniXNU. It builds on
[edk2-rk3588](https://github.com/edk2-porting/edk2-rk3588) without modifying it: upstream's own Orange Pi 5
board files (PCDs, ACPI tables, device trees, logo) are used where they live, this repository adds the UniXNU
packages through `PACKAGES_PATH`, and the result is an 8 MB SPI NOR image (GPT + idblock + FIT with BL31,
OP-TEE and the UEFI firmware volume).

Companion repositories: `UniXNU-orangepi5` (board configuration, kernel side), `UniXNU-rk3588-common` (SoC support).
Derived from [`uefi-evb10`](https://github.com/Ken-u/uefi-evb10).

## Layout

| Path | Contents |
| --- | --- |
| `UniXNUOrangePi5/UniXNUOrangePi5.dsc`, `.Modules.fdf.inc` | The platform: upstream's Orange Pi 5 values plus the UniXNU modules and the watchdog |
| `UniXNUOrangePi5/Library/UniXNUPlatformLib` | ArmPlatformLib with the EL2 to EL1 drop DarwinBoot needs |
| `UniXNUOrangePi5/Library/RockchipPlatformLib` | Copy of upstream's Orange Pi 5 library; only `vdd_gpu_s0` differs (`GPU_RAIL_UV`, 750 mV) |
| `UniXNUOrangePi5/BootWdt` | Hardware watchdog safety net (the board has no remote power switch) |
| `build.sh` | Builds the firmware and packs the NOR image |
| `tools/board/` | Board tools: `make-bundle.sh` (payload and everything for the board in one directory), `nvme-install.py` (GPT, ESP and root image onto the NVMe drive, with read-back), `spi-flash.sh` (SPI NOR with backup), `capture.sh` and `capture-remote.sh` (serial log with times, locally or through the board host), `patch-payload-toml.py` |
| `docs/first-boot.md` | What to connect, how to write the drive and the flash, what the first log should show |

There is no RAM-disk driver here: the payload is the ESP of the NVMe drive in the M.2 slot, which the firmware's
NvmExpressDxe, PartitionDxe and FAT driver expose like any other file system.

## Build

Paths of the machine go into `.env` (git-ignored, template `.env.example`). Required: an edk2-rk3588 checkout with
submodules (`UPSTREAM`), a UniXNU checkout (`UNIXNU`), clang (`CLANG_BIN`) and `iasl` on `PATH`.

```sh
./build.sh -b DEBUG             # firmware + NOR image into out/
```

Outputs in `out/`: `RK3588_NOR_FLASH-unixnu-orangepi5.img` (8 MB, the flashable image), `BL33_AP_UEFI-orangepi5.Fv`,
`unixnu-orangepi5_EFI.itb` and the single modules (`UniXNU.efi`, `UniXNUDxe.efi`, `DarwinBoot.efi`). DEBUG is
required for bring-up: the serial log depends on it.

## Status

Builds on the host (modules present in the firmware volume: Vop2Dxe, DwHdmiQpLib, NvmExpressDxe, UniXNU,
UniXNUDxe, DarwinBoot, UniXNUBootWdtDxe). The board tools ran on the host against a file-backed 128 GB image (`nvme-install.py --selftest`
and a full install with read-back). **Not yet run on a board.**

## License

BSD-2-Clause-Patent, see `LICENSE`. The platform files derive from edk2-rk3588 and EDK II (also BSD-2-Clause-Patent).
