# First boot of the Orange Pi 5

Procedure for putting the firmware, the payload and the root image on the board, and what the serial log should show. Everything
here was prepared and checked on the build host; **nothing has run on the board yet**. "Expected" below is a plan, and each step
says which log line settles it.

The board in this plan: Orange Pi 5, 8 GiB LPDDR4x, a 128 GB (about 119 GiB) NVMe drive in the M.2 M-key slot, an HDMI monitor.

## 0. What is needed

| | |
| --- | --- |
| Serial | A 3.3 V USB serial adapter that supports **1 500 000 baud** (FT232R/FT232H, CP2102N) on the 3-pin debug header: board TX to adapter RX, GND to GND, **do not connect 3.3 V**. Check the silkscreen for the pin order. 8N1, no flow control |
| Linux on the board | Orange Pi OS (or any Linux) booted from an **SD card**, with network or a USB disk to bring the bundle over. It must not be booted from the NVMe drive: the installer refuses a drive with a mounted partition |
| `mtd-utils` | `apt install mtd-utils` on that Linux (`flashcp`), only for writing the SPI NOR from Linux |
| Display | HDMI monitor on the HDMI port of the board |
| Power | The board's USB-C supply. There is no reset line and no power button: a hang ends in the watchdog reset, a hung firmware needs the plug pulled |

A box of caveats before starting:

- The NVMe drive is erased (GPT, ESP and the first 64 GiB). Take anything you want off it first.
- The SPI NOR flash is overwritten. `spi-flash.sh` saves the old content first; keep that file (`spi-backup/`) somewhere that is not the board.
- A 4096-byte-block NVMe drive is refused by the installer (the driver speaks 512-byte blocks). Most consumer drives are 512; `nvme id-ns /dev/nvme0n1 -H` tells.

## 1. Build the bundle (build host)

```sh
cd uefi-orangepi5
./build.sh -b DEBUG                                   # firmware, if it is not built yet: out/RK3588_NOR_FLASH-unixnu-orangepi5.img
cd ../UniXNU-orangepi5 && source ../host/env.sh && scripts/build-orangepi5-kernel.sh      # kernel, if not built yet
cd ../uefi-orangepi5 && REBUILD=1 tools/board/make-bundle.sh                               # payload + bundle in out/bundle
```

`out/bundle` then holds `nor.img` (firmware), `esp.img` (payload volume), `userdata-root.img` (the 17.7.11 root image, 9.4 GB),
`layout.json`, `SHA256SUMS`, `nvme-install.py`, `spi-flash.sh`, `esp-files/` (the ESP's files, for a USB stick) and
`maskrom/` (the loader for a PC in Maskrom mode; both are outside `SHA256SUMS`). The root image is the one of the EVB10 port (same IPSW, board
independent); `ROOT_IMAGE` in `.env` names it, or build one with `unixnu build userdata --ipsw ...`.

Host checks that ran (build host, see the commit messages for the revisions): `nvme-install.py --selftest` with five mutants of
the GPT writer and the drive checks (all caught); a full install of this bundle into a 128 GB sparse file, read back and compared;
the GPT read with the driver's own reader (`package/Rk3588Nvme/tests/check-gpt-image.cpp`), with `fdisk` and `sfdisk --verify`;
the payload's FAT volume read with mtools; the exported `pcie-nvme` node in the payload's device tree.

## 2. Copy it to the board

```sh
rsync -aL --partial --info=progress2 out/bundle/ USER@BOARD:~/unixnu-bundle/      # -L: the big files are symbolic links
```

No network on the board's Linux: `cp -L` the bundle to an ext4 or exFAT USB disk, or `rsync` through the board host (`-e "ssh -J HOST"`).
On the board: `cd ~/unixnu-bundle && sha256sum -c SHA256SUMS` (about a minute).

## 3. Write the NVMe drive

```sh
sudo python3 nvme-install.py . --device /dev/nvme0n1                  # dry run: names the drive, shows the plan
sudo python3 nvme-install.py . --device /dev/nvme0n1 --write --expect-bytes N     # N from the dry run
```

It writes GPT + ESP + root image, zeroes the header of the Data window and reads it all back with `O_DIRECT`; it ends with
`OK: gpt, esp, root, data verified`. Layout: ESP LBA 2048 (256 MiB), `userdata` LBA 526336..134744063 (64 GiB; the root image at its
start, the Data window of 2 GiB at its end).

Later updates of the payload only (a new kernel): build the bundle again and write just the ESP, which takes seconds:

```sh
sudo python3 nvme-install.py . --device /dev/nvme0n1 --parts esp --write --expect-bytes N
```

## 4. Write the SPI NOR

```sh
sudo ./spi-flash.sh .                 # dry run: finds the flash in /proc/mtd, checks nor.img
sudo WRITE=1 ./spi-flash.sh .         # backup to ../spi-backup/, flashcp (erase, write, compare), compare again
```

`/proc/mtd` must list the flash (16 MiB on the Orange Pi 5). If it does not, the Linux in use has not enabled it: use the Maskrom
way of the Rock 5 low-level documentation (<https://docs.radxa.com/en/rock5/lowlevel-development/bootloader_spi_flash>), the Orange Pi 5
uses the same procedure with its own Maskrom button. The loader that a PC in Maskrom mode needs first is
`out/bundle/maskrom/rk3588_loader_v1.24.114.bin` (`tools/board/make-loader.sh`: rkbin's `boot_merger` over `RKBOOT/RK3588MINIALL.ini`,
DDR v1.24 + usbplug v1.11 + SPL v1.14; built on the build host, never tried on this board). With RKDevTool: load that file as the
loader, then write `nor.img` at address 0; with `rkdeveloptool`: `db <loader>`, then `wl 0 nor.img`.

If the new firmware does not come up, the way back is `flashcp -v spi-backup/spi-*.bin /dev/mtdN` from a Linux that still boots (SD
card; a bootable SPI image takes precedence over the SD card, so this needs the Maskrom button or the recovery boot option of the
firmware, see the Recovery section of the edk2-rk3588 README: F4 at the splash screen, or Recovery button at power-on).

## 5. First power-on

1. Power off. Connect the serial adapter, the HDMI monitor, keep the NVMe in.
2. On the machine with the adapter: `tools/board/capture.sh m0 300` (log in `runs/m0.ts` with times, `runs/m0.raw` as received), or from the
   build host when the adapter is on the board host (`BOARD_HOST` in `.env`): `tools/board/capture-remote.sh m0 300`, which copies the log back.
   Start it before the power goes on.
3. Plug the power in. For the very first run press a key when the UniXNU menu appears and choose `xnu-probe` (see step 6); otherwise the menu starts `xnu` after 3 seconds.

On HDMI only the firmware's own screens appear in this build (logo, then the menu). The kernel has no display driver yet: **its output
is on the serial port only**. A black monitor after the menu is expected.

## 6. What the log should show

Search with `rg -n 'PATTERN' runs/m0.ts`.

| Step | Lines | If it fails |
| --- | --- | --- |
| Firmware | DDR banner, `BL31`, UEFI banner `UniXNU` / `Orange Pi 5 (UniXNU)`, the UniXNU menu, `DARWINBOOT:` lines | Nothing on serial at all: wrong pins or baud (1500000); LED does not light: no firmware. Firmware ASSERT: send `runs/m0.ts` |
| Memory | the UEFI memory map (DEBUG build) with a conventional range of at least 2 GiB | `Out of Resources` from DarwinBoot: lower `payload.adt.owned_memory_size` |
| Kernel start | `NativeNvme: matched ...` | no line: the personality or the ADT node `pcie-nvme` is not there (`strings kernel.macho.adt`) |
| PCIe | `pcie: LTSSM 0x11 (L0), root port link status ...: Gen2 x1`, then `pcie: 00:00.0 vendor ... class 0x10802`, `BAR0 ...` | LTSSM not L0: the firmware did not bring the link up (UEFI setup, Advanced, Rockchip platform configuration, PCIe/SATA/USB). `nothing answers at 00:00.0`: the controller address assumptions are wrong or no drive. `BAR0 ... lies in none of the windows`: the BAR is elsewhere than derived |
| NVMe | `NVMe 1.x ...`, `controller as the firmware left it: CC ... CSTS ...`, `namespace 1: N blocks of 2^9 bytes`, `queues granted: 1 submission, 1 completion` | a timeout at the first command: DMA window or BAR mapping; the lines before it show CAP/VS and the controller state |
| GPT | `GPT disk ...`, `gpt[0] esp`, `gpt[1] userdata`, `probe 1024 blocks of userdata twice ... (stable)` | a CRC mismatch in the probe: DMA coherence (the cache handling) |
| Root | `root image at block 526336: 2 windows`, `published OS`, `published SystemOS`, `all 2 root windows published` | `no SHNGROOT magic`: the root image is not where the GPT says |
| Data | `data: window lba 130547712..134744063 ... formatting`, `formatted the Data window`, `Data (on the drive) settled` (first boot formats; later boots print `header: ... formatted 1 times` and keep it) | `no persistent Data volume`: the reason is the line before; the RAM disk is used instead, nothing is lost |
| Userland | `launchd`, about a hundred processes after roughly 100 seconds, `watchdogd` | a panic: the text before the restart |

The menu of the payload has four boot entries (any key stops the 3 s countdown; Up/Down and Enter on the serial console):

| Entry | Boot arguments differ from the default by | Use |
| --- | --- | --- |
| `xnu` (default) | | the normal run: root and Data from the drive |
| `xnu-hdmi` | `vc_mirror=1` | the kernel log is drawn on the HDMI frame buffer as well as the serial port (the frame buffer is the GOP one; not tried) |
| `xnu-probe` | `nvme=1 nvme-probe=4096` | find and read the drive, publish nothing; the kernel then waits for a root and restarts. The safest first run: it never writes |
| `xnu-ramdata` | `nvme-data-persist=0` | the Data volume lives in RAM; the drive is only read |

`Restart` is the last entry; there is no power-off entry (it would cut the supply for good, see `patch-payload-toml.py`).

Other arguments for a run (`EXTRA_KERNEL_ARGS="..." REBUILD=1 tools/board/make-bundle.sh`, then write the ESP): `nvme-probe=N` (blocks of
`userdata` to double-read, default 1024), `nvme-data-reset=1` (format the Data window again), `wdt-kick=330` (feed the watchdog for 330 s
only, to see the reset path early).

## 7. After the first log

What changes in the files, not in the kernel, once the log shows the real values:

- the memory map: `dts/orangepi5.dts` memory node and `payload.dram_size` in `UniXNU-orangepi5` (ADT only, no kernel rebuild);
- the owner of the kernel's pages: `payload.adt.owned_memory_size`;
- the PCIe addresses: only if the log disagrees with `package/Rk3588Nvme/README.md` (then `NativeNvme.cpp`, which needs a kernel build).

Then record the observations in `porting.toml` of `UniXNU-orangepi5` with the log as evidence.

## Updating the payload without Linux

`out/bundle/esp-files/EFI/UniXNU/` holds the same files as the ESP of `esp.img` (`unixnu.toml`, `Payloads/kernel.macho`, the ADT,
the trust cache, the Data seed). To replace them on the board without any Linux:

1. Copy the `EFI` directory of `esp-files` to the root of a FAT32 USB stick (`cp -r out/bundle/esp-files/EFI /mnt/stick/`).
2. Power on, press `F1` at the splash (UEFI shell; the firmware image has it, `Shell` is in `FV/Guid.xref` of the build).
3. `map -r`: the line whose device path shows `Pci(...)/NVMe(...)` is the ESP, the one with `USB(...)` is the stick. `ls fsN:\EFI\UniXNU`
   on both to be sure.
4. `cp -r fs1:\EFI\UniXNU\* fs0:\EFI\UniXNU\` (contents into the existing directory; adjust the numbers), `ls -l fs0:\EFI\UniXNU\Payloads`
   to compare sizes, then **take the stick out** (UniXNU reads the first volume that has a `unixnu.toml`, and which one that is
   depends on the enumeration order) and `reset`.

Not tried on this board. If `cp` is refused for the 51 MB kernel, copy `Payloads\kernel.macho` alone first.
