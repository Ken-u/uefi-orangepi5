/*
 * launcher.ld - the layout puts the stub code after the firmware volume on purpose.
 *
 *   +0x000000  64-byte arm64 Image header, code0 branches to the stub at +0x502000
 *   +0x002000  UEFI firmware volume (5 MiB, unchanged)
 *   +0x502000  stub code
 *
 * The stub copies the volume from +0x2000 to 0x200000, so the destination range 0x200000..0x700000 must not reach the code
 * (load address + 0x502000): the file is loaded at 0xa000000, so the code is at 0xa502000.
 */
ENTRY(_head)

SECTIONS
{
	. = 0x0;
	.head : { *(.text.head) }

	. = 0x2000;
	.fv : {
		_fv_start = .;
		KEEP(*(.fv))
		_fv_end = .;
	}

	. = 0x502000;
	.text : { *(.text) *(.text.*) *(.rodata) *(.rodata.*) *(.data) }
	.bss : { *(.bss) *(COMMON) }

	_end = .;
}
