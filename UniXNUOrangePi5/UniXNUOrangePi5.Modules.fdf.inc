## @file
#
#  Main firmware volume module list for the UniXNU Orange Pi 5 build.
#
#  Upstream's Orange Pi 5 list (ACPI, the two device trees, logo), then the
#  UniXNU trio and the watchdog. Everything else (GPIO, display, storage, PCIe,
#  NVMe, USB, network, shell) comes from edk2-rockchip's shared FDF includes
#  unchanged.
#
#  Copyright (c) 2023-2024, Mario Bălănică <mariobalanica02@gmail.com>
#  Copyright (c) 2026, UniXNU contributors. All rights reserved.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

  # ACPI Support
  INF RuleOverride = ACPITABLE Platform/OrangePi/OrangePi5/AcpiTables/AcpiTables.inf

  # Device Tree Support
  INF RuleOverride = DTB Platform/OrangePi/OrangePi5/DeviceTree/Vendor.inf
  INF RuleOverride = DTB Platform/OrangePi/OrangePi5/DeviceTree/Mainline.inf

  # Splash screen logo
  INF $(VENDOR_DIRECTORY)/Drivers/LogoDxe/LogoDxe.inf

  #
  # UniXNU
  #
  # Order matters: the registrar driver looks up the application in the same
  # firmware volume, and DarwinBoot produces the loader protocol UniXNU asks
  # for when a menu entry is of type "xnu".
  #
  INF UniXNUPkg/Application/UniXNU/UniXNU.inf
  INF UniXNUPkg/Driver/UniXNUDxe/UniXNUDxe.inf
  INF DarwinBootPkg/Driver/DarwinBoot.inf

  #
  # Hardware watchdog safety net (see BootWdt/UniXNUBootWdtDxe.c).
  #
  INF $(PLATFORM_DIRECTORY)/BootWdt/UniXNUBootWdtDxe.inf
