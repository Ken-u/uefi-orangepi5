# First boot of the Orange Pi 5

Procedure for putting the firmware, the payload and the root image on the board, and what the serial log should show. Everything
here was prepared and checked on the build host; **nothing has run on the board yet**. "Expected" below is a plan, and each step
says which log line settles it.

The board in this plan: Orange Pi 5, 8 GiB LPDDR4x, a 128 GB (about 119 GiB) NVMe drive in the M.2 M-key slot, an HDMI monitor.

## Two ways to start the firmware

| | U-Boot in the SPI NOR (sections 1 to 6) | edk2 in the SPI NOR (appendix) |
| --- | --- | --- |
| Needs | A U-Boot in the SPI NOR that has NVMe, `ums`, `booti` and distro boot. A Mac (or any machine with `dd`) on the board's USB-C OTG port | An SD card with Linux on the board, or a PC in Maskrom mode |
| SPI NOR | Not written by anything here. The firmware is started from the NVMe drive | Overwritten with `nor.img` |
| How the firmware starts | U-Boot runs `boot.scr` from the ESP, which loads `uefi-launcher.img` (a small stub with the firmware volume inside) and `booti`s it. The stub moves the volume to 0x200000 and jumps in, which is what TF-A does for BL33 in the normal flash flow | BootROM, SPL, TF-A, edk2 |
| edk2 variables | Not stored (the launcher volume is built without the SPI NOR variable store, `./build.sh -L`, so edk2 never writes the SPI that holds U-Boot) | In the SPI NOR |

The first is the plan: the board has no SD card, the NVMe drive is the only storage, and U-Boot (with a working `ums`) is already
in the SPI NOR.

## 1. What is needed

| | |
| --- | --- |
| Serial | A 3.3 V USB serial adapter that supports **1 500 000 baud** (FT232R/FT232H, CP2102N) on the 3-pin debug header: board TX to adapter RX, GND to GND, **do not connect 3.3 V**. Check the silkscreen for the pin order. 8N1, no flow control. U-Boot's console is on this UART, and so is the launcher's and the firmware's |
| U-Boot | In the SPI NOR; on the serial console `help` must list `nvme`, `ums`, `booti`, `load`, `source`. `printenv boot_targets` must contain `nvme` (distro boot, here `mmc1 mmc0 nvme scsi usb pxe dhcp spi`). Nothing in `mmc1`/`mmc0` may be bootable: no SD card |
| A Mac | Connected to the USB port of the board that `ums` shows up on (the one the Mac saw the drive on when it was written the first time), only while `ums` runs; 10 GB free for the images; `rsync`, `shasum`, `dd` |
| Display | HDMI monitor on the HDMI port of the board |
| Power | The board's own supply. There is no reset line and no power button: a hang ends in the watchdog reset, a hung stub needs the plug pulled |

Caveats before starting:

- The NVMe drive is erased (GPT, ESP and the first 64 GiB). Take anything you want off it first.
- A 4096-byte-block NVMe drive does not work (the driver speaks 512-byte blocks). Most consumer drives are 512.

## 2. Build (build host)

```sh
cd uefi-orangepi5
./build.sh -b DEBUG -L                                 # launcher firmware volume: out/launcher/BL33_AP_UEFI-orangepi5-launcher.Fv
cd ../UniXNU-orangepi5 && source ../host/env.sh && scripts/build-orangepi5-kernel.sh      # kernel, if not built yet
cd ../uefi-orangepi5 && REBUILD=1 tools/board/make-bundle.sh                               # payload + launcher into the ESP, bundle in out/bundle
tools/board/make-disk-image.sh                                                             # out/disk: head.img, tail.img, esp.img, SHA256SUMS
```

`make-bundle.sh` builds `out/launcher/uefi-launcher.img` (`tools/stub/build.sh`; the entry point of the volume is read from its reset
vector, 0x1400) and `boot.scr` (`tools/board/boot.cmd` through `make-bootscr.py`) and copies both to the root of the ESP. `out/bundle/uboot/`
has the same files for loading them by hand. `make-disk-image.sh` puts the bundle through `nvme-install.py` (the code that would write
a real drive, with its read-back) into a sparse file the size of the drive and cuts out the parts a `dd` has to write:

| File | Covers | Written at |
| --- | --- | --- |
| `head.img` (about 9.65 GB) | MBR, GPT, ESP, root image | the start of the drive |
| `tail.img` (16 896 bytes) | the backup GPT | sector `size/512 - 33` (250069647 for 128035676160 bytes) |
| `esp.img` (256 MiB) | the ESP alone, always the newest | 1 MiB (LBA 2048), after `head.img` and for every later update |

`DISK_BYTES=N tools/board/make-disk-image.sh` for a drive of another size (the exact size U-Boot or macOS reports). The root image is
the one of the EVB10 port (same IPSW, board independent); `ROOT_IMAGE` in `.env` names it, or build one with
`unixnu build userdata --ipsw ...`.

Host checks that ran (build host, see the commit messages for the revisions): `nvme-install.py --selftest` with five mutants of
the GPT writer and the drive checks (all caught); a full install of the bundle into a 128 GB sparse file, read back and compared;
the GPT read with the driver's own reader (`package/Rk3588Nvme/tests/check-gpt-image.cpp`), with `fdisk` and `sfdisk --verify`;
the payload's FAT volume read with mtools and `fsck.vfat`; the exported `pcie-nvme` node in the payload's device tree;
`boot.scr` against `mkimage -T script` (byte for byte with `make-bootscr.py --table-end 0`; the default differs in one word, see the table of section 4); the stub's instructions against the EVB10 stub that ran on a board (identical;
only the strings and the `text_offset` field of the header differ).

## 3. Write the drive from the Mac (`ums`)

On the board's serial console (U-Boot prompt; press a key in the autoboot countdown):

```
nvme scan
nvme info                    # the drive's size in blocks: 250069680 x 512 for the 128 GB drive
ums 0 nvme 0                 # the drive is now a USB disk on the OTG port; Ctrl-C ends it
```

On the Mac:

```sh
rsync -aP --partial BUILDHOST:path/to/uefi-orangepi5/out/disk/ ~/unixnu-disk/ && cd ~/unixnu-disk && shasum -a 256 -c SHA256SUMS
diskutil list                # find the new disk (about 128 GB); its number is N below. "unreadable disk, initialise?": click Ignore
diskutil info /dev/diskN | grep -E 'Disk Size|Block Size'    # 128035676160 bytes, 512
```

macOS mounts the ESP as soon as a new GPT shows up and `dd` then fails with `Resource busy`: unmount before **each** command.

```sh
diskutil unmountDisk /dev/diskN && sudo dd if=head.img of=/dev/rdiskN bs=4m              # Ctrl+T shows progress
diskutil unmountDisk /dev/diskN && sudo dd if=tail.img of=/dev/rdiskN bs=512 seek=250069647
diskutil unmountDisk /dev/diskN && sudo dd if=/dev/zero of=/dev/rdiskN bs=1m count=1 seek=63744   # header of the Data window
diskutil unmountDisk /dev/diskN && sudo dd if=esp.img of=/dev/rdiskN bs=1m seek=1                  # the ESP is newer than the one in head.img
diskutil unmountDisk /dev/diskN; sudo dd if=/dev/rdiskN bs=1m skip=1 count=256 | shasum -a 256   # equals the esp.img line of SHA256SUMS
```

`seek=250069647` and `seek=63744` are for the 128035676160-byte drive; `make-disk-image.sh` prints the numbers for the size it was given.
Then `Ctrl-C` on the serial console to leave `ums`, and check the drive from U-Boot:

```
nvme scan
part list nvme 0             # 1 esp (LBA 2048..526335), 2 userdata (LBA 526336..134744063)
ls nvme 0:1                  # boot.scr, uefi-launcher.img, EFI/
```

Later updates of the payload (a new kernel): `REBUILD=1 tools/board/make-bundle.sh`, copy `out/disk/esp.img`, `ums`, and only the
`esp.img` line above. It takes seconds and does not touch the root image or the Data volume.

## 4. First power-on

1. Power off. Connect the serial adapter and the HDMI monitor, keep the NVMe in, no SD card.
2. On the machine with the adapter: `tools/board/capture.sh m0 300` (log in `runs/m0.ts` with times, `runs/m0.raw` as received), or from the
   build host when the adapter is on the board host (`BOARD_HOST` in `.env`): `tools/board/capture-remote.sh m0 300`, which copies the log back.
   Start it before the power goes on.
3. Plug the power in and leave U-Boot alone. Distro boot looks at the first partition of each drive in `boot_targets`: no
   `extlinux/extlinux.conf` there, then `boot.scr`, which is the launcher's. If U-Boot stopped at its prompt: `run bootcmd`.
4. The bundle's menu starts `xnu-probe` by itself after 10 seconds (it reads the drive and writes nothing, see section 6), so nothing has
   to be pressed for the first run. To start something else, press a key in the countdown and pick it (Up/Down, Enter on the serial console).

The launcher's part of the log, in order:

```
UniXNU launcher: nvme 0:1                       from boot.scr
5251560 bytes read in ... ms                    uefi-launcher.img loaded at 0xa000000
## Booting kernel from Legacy Image ... / Starting kernel ...    (the wording depends on U-Boot)
LAUNCHER: EL=2 copying the firmware volume to 0x200000
LAUNCHER: DW WDT 0xfeaf0000 armed (TORR 0xf), UniXNUBootWdtDxe takes over feeding
LAUNCHER: jumping to 0x200000 + 0x1400
UEFI banner of the firmware ...
```

If it does not look like this:

| What the log shows | Meaning and next step |
| --- | --- |
| U-Boot tries `mmc`, `nvme`, ..., ends at `pxe`/`dhcp` without `UniXNU launcher:` | `boot.scr` not found or the drive not scanned: at the prompt `nvme scan; ls nvme 0:1`. By hand: `load nvme 0:1 0xa000000 uefi-launcher.img` then `booti 0xa000000 - ${fdtcontroladdr}` |
| `UniXNU launcher: no uefi-launcher.img` | the file is not on that partition: section 3 |
| `booti` complains (`Bad Linux ARM64 Image magic`, overlaps, `Wrong Image Format`) | the load failed or the address is taken: send the lines. The image has the Linux arm64 header with `text_offset` 0xa000000 |
| `Starting kernel ...`, nothing from `LAUNCHER:` | the stub did not run, or the UART is not 0xfeb50000 (UART2, what the debug header uses on this board). The stub only prints on that UART |
| `LAUNCHER: EL=...` but no UEFI banner, the board resets after about 90 s | the watchdog fired: the firmware hung before DXE. The log up to the reset is what is needed |
| UEFI banner, then a hang in PCIe or NVMe code | see the table of section 5 |

Seen on the Orange Pi 5 (2026-11-03, `UniXNU-orangepi5/evidence/device-first-boot-20261103.txt`): `boot.scr` starts the launcher by itself,
also after the restart that follows a kernel panic; `booti` leaves the stub where it was loaded; the firmware gets U-Boot's device tree in x0
(one `Bad transfer list signature 0xEDFE0DD0` line, harmless: x0 is not a transfer list); the firmware brings the PCIe link up again after
U-Boot has used the drive. Not exercised: the hardware watchdog resetting a hung firmware or kernel (a kernel panic restarts the board at once).

**`boot.scr` and this board's U-Boot.** A `boot.scr` as `mkimage -T script` writes it (size table `length, 0`) made this U-Boot print
`Unknown command '<garbage>'`: it counts the entries of a script image up to a word of `0xffffffff`, not up to 0, so it ran past the end of the
file and took the text from behind it. `make-bootscr.py` therefore ends the table with `0xffffffff` (`iminfo` then lists one image and `source`
runs the text); `--table-end 0` writes mkimage's layout for a U-Boot that wants that. The test is `python3 tools/board/test-bootscr.py`.

**Keys on the serial console without a person:** `CAPTURE_ARGS="--send 'menu: shown' text:1" tools/board/capture-remote.sh TAG 480` types `1`
(the first menu entry, `xnu`) in the countdown; the same reader captures the log. In the menu a digit `N` boots entry `N` (1 `xnu`,
2 `xnu-hdmi`, 3 `xnu-probe`, 4 `xnu-ramdata`), Up/Down and Enter or space also work. From the U-Boot prompt the board restarts with `reset`
(typed on the serial console; there is no reset controller on this board), after which U-Boot runs `boot.scr` again.

On HDMI the firmware's screens appear (logo, then the menu). The kernel has no display driver yet: **its output is on the serial port**,
and the `xnu-hdmi` entry (`vc_mirror=1`) copies the kernel log to the GOP frame buffer as well (seen on the monitor on 2026-11-03: the log scrolls). With `xnu` or `xnu-probe` the monitor goes
black after the menu, as expected.

The USB serial adapter drops off the bus when the board resets (watchdog or panic) and returns under another name (`ttyUSB0` to
`ttyUSB1`). Put `/dev/serial/by-id/...` in `.env` as `BOARD_SERIAL_DEV`; `serial-capture.py` stops with `# device closed` when the line
goes away, so a capture that falls silent in the middle is not a quiet board.

## 5. What the log should show

Search with `rg -n 'PATTERN' runs/m0.ts`.

| Step | Lines | If it fails |
| --- | --- | --- |
| Firmware | the `LAUNCHER:` lines, UEFI banner `UniXNU` / `Orange Pi 5 (UniXNU)`, the UniXNU menu, `DARWINBOOT:` lines | Firmware ASSERT: send `runs/m0.ts` |
| Memory | `MEMMAP:` lines (`UniXNUMemMapDxe`, DEBUG build) before the menu and at ExitBootServices: `largest run 4096 MiB at 0x100000000` on the 8 GiB board; `DARWINBOOT: ARM64 ... pa=0x10007C000 ... owned=0xF8000000`, `vm_page_bootstrap: 981518 free pages` | `boot refused: Out of Resources` from DarwinBoot: no free run is as long as `payload.adt.owned_memory_size`; lower it below the largest run (the menu then waits for a key: type `5`) |
| Kernel start | `NativeNvme: matched ...` | no line: the personality or the ADT node `pcie-nvme` is not there (`strings kernel.macho.adt`) |
| PCIe | `pcie: LTSSM 0x30011 (L0, link up), root port link status ...: Gen1 x1`, then `pcie: 00:00.0 vendor ... class 0x10802`, `BAR0 0xf0000000 (64-bit, not prefetchable) is at CPU address 0xa38000000` (what the first run printed) | LTSSM not L0: the firmware did not bring the link up (UEFI setup, Advanced, Rockchip platform configuration, PCIe/SATA/USB; the firmware has to do it again after U-Boot). `nothing answers at 00:00.0`: the controller address assumptions are wrong or no drive. `BAR0 ... lies in none of the windows`: the BAR is elsewhere than derived |
| NVMe | `NVMe 1.x ...`, `controller as the firmware left it: CC ... CSTS ...`, `namespace 1: N blocks of 2^9 bytes`, `queues granted: 1 submission, 1 completion` | a timeout at the first command: DMA window or BAR mapping; the lines before it show CAP/VS and the controller state |
| GPT | `GPT disk ...`, `gpt[0] esp`, `gpt[1] userdata`, `probe 1024 blocks of userdata twice ... (stable)` | a CRC mismatch in the probe: DMA coherence (the cache handling) |
| Root | `root image at block 526336: 2 windows`, `published OS`, `published SystemOS`, `all 2 root windows published` | `no SHNGROOT magic`: the root image is not where the GPT says |
| Data | `data: window lba 130547712..134744063 ... formatting`, `formatted the Data window`, `Data (on the drive) settled` (first boot formats; later boots print `header: ... formatted 1 times` and keep it) | `no persistent Data volume`: the reason is the line before; the RAM disk is used instead, nothing is lost |
| Userland | `launchd`, about a hundred processes after roughly 100 seconds, `watchdogd` | a panic: the text before the restart |

## 6. Boot entries

The menu of the payload has four boot entries (any key stops the countdown, 10 s in the bundle; Up/Down and Enter on the serial console). The bundle's default entry is `xnu-probe`; once the log is good, `DEFAULT_ENTRY=xnu MENU_TIMEOUT=3 tools/board/make-bundle.sh` makes `xnu` the default, and the new `out/disk/esp.img` is written as in section 3:

| Entry | Boot arguments differ from the default by | Use |
| --- | --- | --- |
| `xnu` | | the normal run: root and Data from the drive (writes the Data window of the drive) |
| `xnu-hdmi` | `vc_mirror=1` | the kernel log is drawn on the HDMI frame buffer as well as the serial port (the frame buffer is the GOP one; not tried) |
| `xnu-probe` (default of the bundle) | `nvme=1 nvme-probe=4096` | find and read the drive, publish nothing; the kernel then waits for a root and restarts. The safest first run: it never writes |
| `xnu-ramdata` | `nvme-data-persist=0` | the Data volume lives in RAM; the drive is only read |

`Restart` is the last entry; there is no power-off entry (it would cut the supply for good, see `patch-payload-toml.py`).

Other arguments for a run (`EXTRA_KERNEL_ARGS="..." REBUILD=1 tools/board/make-bundle.sh`, then write the ESP): `nvme-probe=N` (blocks of
`userdata` to double-read, default 1024), `nvme-data-reset=1` (format the Data window again), `wdt-kick=330` (feed the watchdog for 330 s
only, to see the reset path early).

## 7. After the first log

What changes in the files, not in the kernel, once the log shows the real values:

- the memory: `payload.adt.owned_memory_size` below the largest run of the `MEMMAP:` log, and the memory node of `dts/orangepi5.dts` with `payload.dram_size` equal to it in `UniXNU-orangepi5` (ADT only, no kernel rebuild; done for the 8 GiB board: 3.875 GiB in the 4 GiB bank, see `UniXNU-orangepi5/docs/bring-up.md`; the run is one piece only with the two firmware settings of `dc08d7c` and `e1ac136`);
- the PCIe addresses: only if the log disagrees with `package/Rk3588Nvme/README.md` (then `NativeNvme.cpp`, which needs a kernel build).

Then record the observations in `porting.toml` of `UniXNU-orangepi5` with the log as evidence.

## Appendix: edk2 in the SPI NOR (SD card and Linux)

The other way, for a board that has an SD card and no usable U-Boot: edk2 itself goes into the SPI NOR (`nor.img`, from `./build.sh` without
`-L`) and starts at power-on. The NVMe drive is written from a Linux on the board (booted from the SD card, not from the NVMe drive: the
installer refuses a drive with a mounted partition).

```sh
rsync -aL --partial --info=progress2 out/bundle/ USER@BOARD:~/unixnu-bundle/      # -L: the big files are symbolic links
# on the board: cd ~/unixnu-bundle && sha256sum -c SHA256SUMS
sudo python3 nvme-install.py . --device /dev/nvme0n1                  # dry run: names the drive, shows the plan
sudo python3 nvme-install.py . --device /dev/nvme0n1 --write --expect-bytes N     # N from the dry run
sudo python3 nvme-install.py . --device /dev/nvme0n1 --parts esp --write --expect-bytes N     # later: the ESP only
sudo ./spi-flash.sh .                 # dry run: finds the flash in /proc/mtd, checks nor.img
sudo WRITE=1 ./spi-flash.sh .         # backup to ../spi-backup/, flashcp (erase, write, compare), compare again
```

`mtd-utils` (`flashcp`) is needed for the last one, and `/proc/mtd` must list the flash (16 MiB on the Orange Pi 5). `spi-flash.sh`
saves the old content first: keep that file somewhere that is not the board. The installer ends with `OK: gpt, esp, root, data verified`.

If the Linux in use has not enabled the SPI flash, or the board has no SD card, use the Maskrom way of the Rock 5 low-level
documentation (<https://docs.radxa.com/en/rock5/lowlevel-development/bootloader_spi_flash>); the Orange Pi 5 uses the same procedure with
its own Maskrom button. The loader that a PC in Maskrom mode needs first is `out/bundle/maskrom/rk3588_loader_v1.24.114.bin`
(`tools/board/make-loader.sh`: rkbin's `boot_merger` over `RKBOOT/RK3588MINIALL.ini`, DDR v1.24 + usbplug v1.11 + SPL v1.14; built on the
build host, never tried on this board). With RKDevTool: load that file as the loader, then write `nor.img` at address 0; with
`rkdeveloptool`: `db <loader>`, then `wl 0 nor.img`. The board host has Rockchip's `upgrade_tool` (`/usr/bin/upgrade_tool`) but no
`rkdeveloptool`; the build host has neither. `upgrade_tool` has the same `db` / `wl` commands, but whether it writes the SPI NOR of this
board was not checked. The USB-C port of the board has to be connected to that machine for either. The same loader is the way back for
the U-Boot route if the SPI NOR ever has to be rewritten.

If the new firmware does not come up, the way back is `flashcp -v spi-backup/spi-*.bin /dev/mtdN` from a Linux that still boots (SD
card; a bootable SPI image takes precedence over the SD card, so this needs the Maskrom button or the recovery boot option of the
firmware, see the Recovery section of the edk2-rk3588 README: F4 at the splash screen, or Recovery button at power-on).

The first power-on and the log are as in sections 4 and 5, without the `LAUNCHER:` lines.

### Updating the payload without Linux (edk2 in the SPI NOR)

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

## 9. Replacing files on the ESP from the U-Boot prompt (no Mac, nobody at the board)

For files that change often (`kernel.macho.adt`, `unixnu.toml`, even `uefi-launcher.img`) the `ums` route is not needed: the serial console
of the board is enough. The board host runs `uboot-put.py` and `uboot-cmd.py` (both from `UniXNU-rk3588-common/tools/board`, copied there
with `scp`; `SERIAL_DEV` is the by-id path, `BOARD_SERIAL_DEV` in `.env`).

1. Get the U-Boot prompt. This U-Boot's autoboot ("Hit key to stop autoboot('CTRL+C')") is stopped by `Ctrl-C` only; other keys do not. The countdown line is not complete until it ends, so a capture cannot match it: match the earlier banner and type
   `Ctrl-C` many times: `CAPTURE_ARGS="--send 'U-Boot v' ctrl-c,ctrl-c,ctrl-c,ctrl-c,ctrl-c,ctrl-c,ctrl-c,ctrl-c --stop '<INTERRUPT>' 1 'at the U-Boot prompt'"`.
   The board reaches a banner by itself: a kernel panic restarts it in a second, the `xnu-probe` entry panics about 20 s after the hand-off
   (84 s per round), the watchdog resets it 89 s after the feeding ends, and the menu entry `Restart` (key `5`) resets it.
2. `python3 uboot-put.py FILE 0x1000000` sends the file with YMODEM (`loady`) at the console's 1.5 Mbaud (about 40 s for the 5 MiB launcher, instant
   for the ADT) and compares `crc32` in U-Boot with its own. After a good transfer this U-Boot prints "Timed out" and "download aborted";
   only the `crc32` line decides.
3. In U-Boot, all numbers are **hex**: `nvme scan`, `fatwrite nvme 0:1 0x1000000 EFI/UniXNU/Payloads/kernel.macho.adt 0x3720` (the size of 14112 bytes;
   with the decimal number U-Boot wrote 82194 bytes), `fatload nvme 0:1 0x3000000 EFI/UniXNU/Payloads/kernel.macho.adt`, `crc32 0x3000000 0x3720`.
   The last number must equal the one of the first step; `fatload` must print the same size.
4. `run bootcmd` boots from the ESP again (no new banner is printed before the firmware's own).

`tools/board/esp-put.sh LOCALFILE ESPPATH` does all of this for one file (pieces, prompt polling, the safe addresses, the read back and the
`VERIFIED` line; `--dry-run` prints the plan). It has written the kernel, the ADT and `unixnu.toml` to the board and printed `VERIFIED` for each
(2026-11-05; the 51 MB kernel takes about 20 minutes). Two things learned with the 51 MB kernel (2026-11-03, display build):

- Do not read or `crc32` a RAM range that reaches 0x8400000 (protected memory, the trusted firmware's): `crc32 0x6000000 0x30e9000` ended in
  `"Synchronous Abort" handler, esr 0x96000010, far 0x8400000`, U-Boot printed "Resetting CPU ..." and "### ERROR ### Please RESET the board ###"
  and hung, and nothing but pulling the plug brought the board back (there is no reset line, the watchdog is not armed in U-Boot). Put the data at
  0x1000000 (up to 0x8400000 is 116 MiB, enough for the 51 MB kernel) and read it back for `crc32` at 0xa000000 or above.
- `uboot-put.py` used to give up with "the header packet was refused" on larger files and shortly after another transfer: the U-Boot sometimes
  does not take the header after its first `C`, keeps sending `C` once a second and NAKs some seconds later. The tool now sends the header
  again every 2.5 s until it is acknowledged (UniXNU-rk3588-common a37ea4b). A transfer runs at about 60-70 KB/s (16 MiB in 4 minutes), so the
  kernel goes in four pieces of 16 MiB at 0x1000000, 0x2000000, 0x3000000 and 0x4000000 (the last one is 954368 bytes, ending at 0x40e9000),
  each checked by its own `crc32`, followed by one `fatwrite nvme 0:1 0x1000000 EFI/UniXNU/Payloads/kernel.macho 0x30e9000` (51286016 bytes written in
  237 ms) and `fatload nvme 0:1 0xa000000 EFI/UniXNU/Payloads/kernel.macho` with `crc32 0xa000000 0x30e9000` over the whole. After a transfer the
  U-Boot needs about a minute before a new `loady` is taken; poll the prompt with `echo hi` first.

`tools/board/esp-put-delta.sh LOCALFILE ESPPATH` is the same for a file that is already on the ESP in an older version (a kernel rebuilt after a
driver change has the same size and differs in a few places). U-Boot reads the old file into RAM, takes the `crc32` of every 1 MiB block, and only
the blocks that differ cross the serial line (blocks at most `MERGE_GAP`=3 apart go in one transfer, since U-Boot needs about a minute between two
`loady`); then the whole file is written and read back as above (`VERIFIED ... (sent N)`). On the board (2026-11-05, kernel of 51757056 bytes, one
driver changed): 24 of 50 blocks differed, 25542656 bytes were sent instead of 51757056, and the read-back `crc32` matched. The relinked kernel
of a bigger change differs in most blocks and then costs what `esp-put.sh` costs.

The capture of a run then ends by itself at the next U-Boot banner. The runs of the memory work (`evidence/device-memory-20261103.txt` of
`UniXNU-orangepi5`) were all made this way; the files that went to the ESP were checked by `crc32` before every boot.

## 10. Replacing the whole ESP over rockusb (fast, the board's USB-C on the board host)

When the board's OTG port is cabled to a host that has Rockchip's `upgrade_tool` (the board host here, v2.44), the ESP is a partition of
the drive and can be written in one go; the serial-line copy of section 9 is only for when nobody can cable the board.

1. Build the image: `REBUILD=1 tools/board/make-bundle.sh` (add `DEFAULT_ENTRY=xnu MENU_TIMEOUT=3` for the boot-straight-in menu), then
   `tools/board/make-disk-image.sh`; `out/disk/esp.img` is the 256 MiB ESP (written at LBA 2048). Copy it to the board host.
2. Get the U-Boot prompt (section 9, step 1) and start the export: `rockusb 0 nvme 0` (do not use `uboot-cmd.py`, it waits for a prompt that
   comes back only after `Ctrl-C`: `printf 'rockusb 0 nvme 0\r' > $BOARD_SERIAL_DEV`). U-Boot prints `RKUSB: LUN 0, dev 0, ... count 0x...` and
   `usb device is super-speed`; `upgrade_tool ld` then lists one device, `Vid=0x2207,Pid=0x350b ... Mode=Loader`.
3. `upgrade_tool di -esp esp.img` writes the partition named `esp` (the GPT label); `upgrade_tool wl 0x800 esp.img` is the same by sector.
   The tool needs write access to the device node. The board host had no rule for 2207:350b (`51-android.rules` lists other ids), so the first
   try printed `Write LBA quit, creating comm object failed!`; a `MODE="0666"` rule for vendor 2207 in `/etc/udev/rules.d` fixes it for good.
4. `di` does not reset the board: U-Boot stays in rockusb mode (its console only prints the spinner) until `upgrade_tool rd` ("Reset Device OK")
   or `Ctrl-C` and `reset` on the console. The board then goes `boot.scr` -> launcher -> menu -> kernel.

On the board (2026-11-05): `di -esp` of the 256 MiB `esp.img` took 1.5 s ("Download image ok"), and the board started the kernel of that image
after `rd` (`mouse1`: the log lines of the new driver code were in the serial log; `esp1` was the same after a `di` run by the person at the board host). **`rl` is not a
read-back that can be trusted here:** `upgrade_tool rl 0x800 0x80000 out.img` right after a `di` returned the first 31 MiB of the image and then
`0xCC` where the image had data (225 of the 256 1 MiB blocks differed from the image, all from 31 MiB on; the sha256 did not match), although the board then booted the new kernel from the
written ESP; so the boot is the check, or `fatload` + `crc32` at the U-Boot prompt.
