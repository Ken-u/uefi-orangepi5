## @file
#
#  UniXNU hosted in upstream edk2-rk3588 firmware, Orange Pi 5 (RK3588S).
#
#  The board-level values (PCDs, ACPI tables, firmware device trees, logo) are
#  upstream's own Orange Pi 5 platform, referenced where they live; this
#  directory adds what UniXNU needs on top, the same way uefi-evb10 does:
#
#    - ArmPlatformLib with an EL2 -> EL1 drop at the start of SEC (DarwinBoot
#      only hands off from EL1; TF-A enters the firmware at EL2);
#    - the UniXNU boot manager, its registrar driver and the XNU loader;
#    - a hardware watchdog safety net (the board has no remote power switch);
#    - a copy of upstream's RockchipPlatformLib whose only change is the
#      vdd_gpu_s0 voltage (GPU_RAIL_UV).
#
#  Unlike the EVB10 build there is no RAM-disk driver: the payload is the ESP of
#  the NVMe drive (EDK II's NvmExpressDxe, PartitionDxe and the FAT driver come
#  from edk2-rockchip's shared includes), which UniXNU finds like any other file
#  system.
#
#  Nothing in the upstream tree is modified. build.sh puts this repository first
#  on PACKAGES_PATH and UniXNU's packages after upstream's.
#
#  Copyright (c) 2014-2018, Linaro Limited. All rights reserved.
#  Copyright (c) 2023, Willzen Zou <github.com/WillzenZou>
#  Copyright (c) 2023-2024, Mario Bălănică <mariobalanica02@gmail.com>
#  Copyright (c) 2026, UniXNU contributors. All rights reserved.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################
[Defines]
  PLATFORM_NAME                  = UniXNUOrangePi5
  PLATFORM_VENDOR                = OrangePi
  PLATFORM_GUID                  = 1899c9f2-cf08-4ff9-b10c-12a563a8949f
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010019
  OUTPUT_DIRECTORY               = Build/$(PLATFORM_NAME)
  #
  # VENDOR_DIRECTORY stays OrangePi so that $(VENDOR_DIRECTORY)/Drivers/LogoDxe
  # resolves to upstream's logo driver. PLATFORM_DIRECTORY is this directory's
  # name (it is on PACKAGES_PATH); upstream's board files are named in full.
  #
  VENDOR_DIRECTORY               = Platform/$(PLATFORM_VENDOR)
  PLATFORM_DIRECTORY             = $(PLATFORM_NAME)
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = Silicon/Rockchip/RK3588/RK3588.fdf
  # GenFds resolves this relative to the platform directory (this DSC's folder).
  RK_PLATFORM_FVMAIN_MODULES     = UniXNUOrangePi5.Modules.fdf.inc

  #
  # HYM8563 RTC support
  # I2C location configured by PCDs below.
  #
  DEFINE RK_RTC8563_ENABLE = TRUE

  #
  # vdd_gpu_s0 in microvolts, set once at boot (RockchipPlatformLib.c). 0.75 V is
  # Rockchip's operating point for the GPU clocks up to 800 MHz; upstream's Orange Pi 5
  # firmware sets 0.85 V. The GPU governor of UniXNU-rk3588-common moves it from here.
  #
  DEFINE GPU_RAIL_UV = 750000

  #
  # RK3588S-based platform
  #
!include Silicon/Rockchip/RK3588/RK3588SPlatform.dsc.inc

################################################################################
#
# Library Class section - list of all Library Classes needed by this Platform.
#
################################################################################

[LibraryClasses.common]
  RockchipPlatformLib|$(PLATFORM_DIRECTORY)/Library/RockchipPlatformLib/RockchipPlatformLib.inf

  # Upstream's RK3588 PlatformLib plus an EL2 -> EL1 drop at the very start of
  # SEC. DarwinBoot only hands off from EL1, TF-A enters us at EL2.
  ArmPlatformLib|$(PLATFORM_DIRECTORY)/Library/UniXNUPlatformLib/UniXNUPlatformLib.inf

  # UniXNU boot manager core, shared by the application and the registrar.
  UniXNULib|UniXNUPkg/Library/UniXNULib/UniXNULib.inf

################################################################################
#
# BuildOptions Section
#
################################################################################

[BuildOptions]
  #
  # Newer clang treats several upstream patterns as errors (RK806.c compares a
  # UINT8 against NA, Edid.c may return an uninitialized status, I2cDxe.c assigns
  # EFI_SUCCESS to a status pointer, the GMAC driver's BITS() macro shifts a negative int). None of them is worth patching an upstream
  # submodule for, so downgrade them to warnings for this platform only.
  #
  *_CLANGDWARF_*_CC_FLAGS = -Wno-error=tautological-constant-out-of-range-compare -Wno-error=sometimes-uninitialized -Wno-error=non-literal-null-conversion -Wno-error=c23-extensions -Wno-error=shift-negative-value -DGPU_RAIL_UV=$(GPU_RAIL_UV)

################################################################################
#
# Pcd Section - list of all EDK II PCD Entries defined by this Platform.
#
################################################################################

[PcdsFixedAtBuild.common]
  # SMBIOS platform config
  gRockchipTokenSpaceGuid.PcdPlatformName|"Orange Pi 5 (UniXNU)"
  gRockchipTokenSpaceGuid.PcdPlatformVendorName|"Orange Pi"
  gRockchipTokenSpaceGuid.PcdFamilyName|"Orange Pi 5"
  gRockchipTokenSpaceGuid.PcdProductUrl|"http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5.html"
  # File name used for /dtb override lookups on the ESP; matches the blobs of upstream's Orange Pi 5.
  gRockchipTokenSpaceGuid.PcdDeviceTreeName|"rk3588s-orangepi-5"

  #
  # I2C (as upstream's Orange Pi 5)
  #
  #   bus 0: rk8602@0x42 (vdd_cpu_big0_s0), rk8603@0x43 (vdd_cpu_big1_s0)
  #   bus 6: hym8563@0x51 (RTC, runtime access), es8388@0x10 (audio codec)
  #
  gRockchipTokenSpaceGuid.PcdI2cSlaveAddresses|{ 0x42, 0x43, 0x51, 0x10 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBuses|{ 0x0, 0x0, 0x6, 0x6 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBusesRuntimeSupport|{ FALSE, FALSE, TRUE, FALSE }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorAddresses|{ 0x42, 0x43 }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorBuses|{ 0x0, 0x0 }
  # The tag is the SCMI clock id of the cluster the regulator feeds; RK3588Dxe
  # looks the big-core regulators up by it to set the 2.4 GHz voltage before boot.
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorTags|{ $(SCMI_CLK_CPUB01), $(SCMI_CLK_CPUB23) }
  gPcf8563RealTimeClockLibTokenSpaceGuid.PcdI2cSlaveAddress|0x51
  gRockchipTokenSpaceGuid.PcdRtc8563Bus|0x6

  #
  # PCIe/SATA/USB Combo PIPE PHY support flags and default values
  #
  # combphy0_ps drives pcie2x1l2, the M.2 M-key slot (the NVMe drive holding the
  # ESP, the root and the Data volume); combphy2_psu is USB 3.
  #
  gRK3588TokenSpaceGuid.PcdComboPhy0Switchable|TRUE
  gRK3588TokenSpaceGuid.PcdComboPhy2Switchable|TRUE
  gRK3588TokenSpaceGuid.PcdComboPhy0ModeDefault|$(COMBO_PHY_MODE_PCIE)
  gRK3588TokenSpaceGuid.PcdComboPhy2ModeDefault|$(COMBO_PHY_MODE_USB3)

  #
  # USB/DP Combo PHY support flags and default values
  #
  gRK3588TokenSpaceGuid.PcdUsbDpPhy0Supported|TRUE
  gRK3588TokenSpaceGuid.PcdDp0LaneMux|{ 0x2, 0x3 }

  #
  # GMAC
  #
  gRK3588TokenSpaceGuid.PcdGmac1Supported|TRUE
  gRK3588TokenSpaceGuid.PcdGmac1TxDelay|0x42

  #
  # I2S
  #
  gRK3588TokenSpaceGuid.PcdI2S1Supported|TRUE

  #
  # On-Board fan output
  #
  gRK3588TokenSpaceGuid.PcdHasOnBoardFanOutput|TRUE

  #
  # Display support flags and default values: HDMI0 (VP0) and the type-C DP.
  #
  gRK3588TokenSpaceGuid.PcdDisplayConnectors|{CODE({
    VOP_OUTPUT_IF_HDMI0,
    VOP_OUTPUT_IF_DP0
  })}

  #
  # UniXNU: keep the boot manager's own log at DEBUG_INFO, the firmware's at
  # its default.
  #
  gUniXNUPkgTokenSpaceGuid.PcdUniXNUDebugLevel|0x00000040

################################################################################
#
# Components Section - list of all EDK II Modules needed by this Platform.
#
################################################################################
[Components.common]
  # ACPI Support (upstream's Orange Pi 5 tables)
  #
  # GenFw takes a table from the start of the .data of its image. With this clang the object of Pptt.aslc has .data.rel.ro (the 8 bytes of
  # ReferenceAcpiTable) before .data (the table), so Pptt.acpi began with 8 stray bytes: the sixth table read from the volume had the signature
  # 0x240 and a length of 0, and the install loop of AcpiLib stopped there (SPCR and the DSDT were never installed, "Couldn't locate ACPI DSDT
  # table"). Sorting the input sections by name puts .data first for every table, as it already is for the others.
  Platform/OrangePi/OrangePi5/AcpiTables/AcpiTables.inf {
    <BuildOptions>
      *_CLANGDWARF_AARCH64_ASLDLINK_FLAGS = -Wl,--sort-section=name
  }

  # Device Tree Support (upstream's blobs for the firmware's /dtb handling; XNU uses its own ADT)
  Platform/OrangePi/OrangePi5/DeviceTree/Vendor.inf
  Platform/OrangePi/OrangePi5/DeviceTree/Mainline.inf

  # Splash screen logo
  $(VENDOR_DIRECTORY)/Drivers/LogoDxe/LogoDxe.inf

  # UniXNU: boot manager application, registrar driver and the XNU loader.
  #
  # DebugLib is overridden for these three: the firmware default is
  # BaseDebugLibSerialPort on the hardcoded RK3588 debug UART (0xfeb50000),
  # which is right on the board but faults under emulation. StdErr goes to
  # ConOut, so the same binaries print on the board's serial console and in
  # QEMU. UniXNU's own log lines already prefer EFI_SERIAL_IO_PROTOCOL.
  UniXNUPkg/Application/UniXNU/UniXNU.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }
  UniXNUPkg/Driver/UniXNUDxe/UniXNUDxe.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }
  DarwinBootPkg/Driver/DarwinBoot.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }

  # Hardware watchdog safety net: this board cannot be power-cycled remotely, so
  # a hung firmware or kernel has to end in a reset by itself. The driver arms
  # the DW watchdog, keeps it fed until ExitBootServices and then leaves the
  # kernel one window (about 89 s) before the SoC resets. The watchdog cannot be
  # disarmed once armed, see BootWdt/UniXNUBootWdtDxe.c for the switches.
  $(PLATFORM_DIRECTORY)/BootWdt/UniXNUBootWdtDxe.inf
  # The UEFI memory map in the serial log (what the kernel's window can be taken from), see MemMap/UniXNUMemMapDxe.c.
  $(PLATFORM_DIRECTORY)/MemMap/UniXNUMemMapDxe.inf
