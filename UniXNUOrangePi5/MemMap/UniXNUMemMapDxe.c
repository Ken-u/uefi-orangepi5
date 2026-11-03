/** @file
  The UEFI memory map on the serial console, for bring-up.

  Why: the kernel's memory is one contiguous window that DarwinBoot takes from a run of EfiConventionalMemory
  (payload.adt.owned_memory_size). Which runs exist depends on what the firmware has allocated by then, and the
  firmware does not say. DarwinBoot draws its own view of it on the screen only when it refuses a window, which
  nobody can read on a board with a 4x-scaled bitmap font that the menu then paints over.

  What it does: a timer event looks at the map once a second and prints it when it differs from the last print
  (the menu waits for a key, so a change is rare: the menu's own allocations, the kernel image DarwinBoot reads
  and its window). At ExitBootServices it prints the map once more, which is the map the kernel's loader left
  behind. Descriptors that touch and have the same type are one line. Nothing is allocated after the entry point:
  the map goes into a static buffer, because ExitBootServices handlers must not allocate.

  Output (one block per print, MiB are of the run):
    MEMMAP: <why>, <n> descriptors, <free> MiB conventional, largest run <MiB> MiB at 0x<start>
    MEMMAP:   0x<start>-0x<end>  <MiB> MiB  <type>
  The blocks go to the serial console through the platform's DebugLib at DEBUG_ERROR level, like the rest of the log.

  Copyright (c) 2026, UniXNU contributors. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>

#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/UefiBootServicesTableLib.h>

//
// 64 KiB hold about 1300 descriptors of 48 bytes: far more than this firmware ever lists (a few dozen).
//
STATIC UINT8      mMap[SIZE_64KB] __attribute__ ((aligned (16)));
STATIC UINT64     mLast;
STATIC EFI_EVENT  mTimer;
STATIC EFI_EVENT  mExit;

STATIC
CONST CHAR8 *
TypeName (
  IN UINT32  Type
  )
{
  switch (Type) {
    case EfiReservedMemoryType:      return "reserved";
    case EfiLoaderCode:              return "loader code";
    case EfiLoaderData:              return "loader data";
    case EfiBootServicesCode:        return "boot services code";
    case EfiBootServicesData:        return "boot services data";
    case EfiRuntimeServicesCode:     return "runtime code";
    case EfiRuntimeServicesData:     return "runtime data";
    case EfiConventionalMemory:      return "free";
    case EfiUnusableMemory:          return "unusable";
    case EfiACPIReclaimMemory:       return "acpi reclaim";
    case EfiACPIMemoryNVS:           return "acpi nvs";
    case EfiMemoryMappedIO:          return "mmio";
    case EfiMemoryMappedIOPortSpace: return "mmio port";
    case EfiPalCode:                 return "pal";
    case EfiPersistentMemory:        return "persistent";
    default:                         return "other";
  }
}

STATIC
VOID
Dump (
  IN CONST CHAR8  *Why,
  IN BOOLEAN      OnlyIfChanged
  )
{
  EFI_STATUS             Status;
  UINTN                  Size;
  UINTN                  Key;
  UINTN                  Stride;
  UINT32                 Version;
  UINTN                  Offset;
  UINT64                 Hash;
  UINT64                 Free;
  UINT64                 BestBytes;
  UINT64                 BestStart;
  UINT64                 Start;
  UINT64                 End;
  UINT32                 Type;
  UINTN                  Count;
  BOOLEAN                Open;
  EFI_MEMORY_DESCRIPTOR  *D;

  Size   = sizeof (mMap);
  Status = gBS->GetMemoryMap (&Size, (EFI_MEMORY_DESCRIPTOR *)mMap, &Key, &Stride, &Version);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "MEMMAP: GetMemoryMap: %r\n", Status));
    return;
  }

  Count = Size / Stride;
  Hash  = 0xcbf29ce484222325ULL;
  for (Offset = 0; Offset + Stride <= Size; Offset += Stride) {
    D     = (EFI_MEMORY_DESCRIPTOR *)(mMap + Offset);
    Hash  = (Hash ^ D->Type) * 0x100000001b3ULL;
    Hash  = (Hash ^ D->PhysicalStart) * 0x100000001b3ULL;
    Hash  = (Hash ^ D->NumberOfPages) * 0x100000001b3ULL;
  }

  if (OnlyIfChanged && (Hash == mLast)) {
    return;
  }

  mLast = Hash;

  //
  // First pass: the free total and the largest run of free descriptors that touch.
  //
  Free      = 0;
  BestBytes = 0;
  BestStart = 0;
  Open      = FALSE;
  Start     = 0;
  End       = 0;
  for (Offset = 0; Offset + Stride <= Size; Offset += Stride) {
    D = (EFI_MEMORY_DESCRIPTOR *)(mMap + Offset);
    if (D->Type != EfiConventionalMemory) {
      Open = FALSE;
      continue;
    }

    Free += LShiftU64 (D->NumberOfPages, EFI_PAGE_SHIFT);
    if (!Open || (D->PhysicalStart != End)) {
      Start = D->PhysicalStart;
    }

    End  = D->PhysicalStart + LShiftU64 (D->NumberOfPages, EFI_PAGE_SHIFT);
    Open = TRUE;
    if (End - Start > BestBytes) {
      BestBytes = End - Start;
      BestStart = Start;
    }
  }

  DEBUG ((
    DEBUG_ERROR,
    "MEMMAP: %a, %lu descriptors, %lu MiB conventional, largest run %lu MiB at 0x%lx\n",
    Why,
    (UINT64)Count,
    RShiftU64 (Free, 20),
    RShiftU64 (BestBytes, 20),
    BestStart
    ));

  //
  // Second pass: touching descriptors of one type are one line.
  //
  Open  = FALSE;
  Start = 0;
  End   = 0;
  Type  = 0;
  for (Offset = 0; Offset + Stride <= Size + Stride; Offset += Stride) {
    D = (Offset + Stride <= Size) ? (EFI_MEMORY_DESCRIPTOR *)(mMap + Offset) : NULL;
    if (Open && ((D == NULL) || (D->Type != Type) || (D->PhysicalStart != End))) {
      DEBUG ((
        DEBUG_ERROR,
        "MEMMAP:   0x%lx-0x%lx  %lu MiB  %a\n",
        Start,
        End,
        RShiftU64 (End - Start, 20),
        TypeName (Type)
        ));
      Open = FALSE;
    }

    if (D == NULL) {
      break;
    }

    if (!Open) {
      Open  = TRUE;
      Start = D->PhysicalStart;
      Type  = D->Type;
    }

    End = D->PhysicalStart + LShiftU64 (D->NumberOfPages, EFI_PAGE_SHIFT);
  }
}

STATIC
VOID
EFIAPI
OnTimer (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  Dump ("changed", TRUE);
}

STATIC
VOID
EFIAPI
OnExitBootServices (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  gBS->SetTimer (mTimer, TimerCancel, 0);
  Dump ("at ExitBootServices", FALSE);
}

EFI_STATUS
EFIAPI
UniXNUMemMapEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;

  Status = gBS->CreateEvent (EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnTimer, NULL, &mTimer);
  if (!EFI_ERROR (Status)) {
    Status = gBS->SetTimer (mTimer, TimerPeriodic, 10000000);
  }

  if (!EFI_ERROR (Status)) {
    Status = gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_NOTIFY, OnExitBootServices, NULL, &gEfiEventExitBootServicesGuid, &mExit);
  }

  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "MEMMAP: events: %r (no memory map in the log)\n", Status));
  }

  return EFI_SUCCESS;
}
