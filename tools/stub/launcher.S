/*
 * launcher.S - move the embedded UEFI firmware volume to 0x200000 and jump into its entry point.
 *
 * The normal edk2-rk3588 path is: the SPI NOR holds a FIT that has BL31 (loaded to 0x60000) and the firmware volume as BL33
 * (loaded to 0x200000); BL31 starts and jumps to 0x200000 with the CPU in EL2. On this board the SPI NOR holds U-Boot instead,
 * so this stub recreates the state "right after BL31": the volume sits at 0x200000, the registers follow the BL33 convention,
 * and the jump goes to the entry point inside the volume. U-Boot starts it with `booti`.
 *
 * The first 64 bytes are an arm64 Linux Image header, so that U-Boot's booti accepts the file. The volume follows at file
 * offset 0x2000 and the code at 0x502000, see launcher.ld; the source address is computed from the address of the code, so
 * the stub does not need to know where U-Boot loaded the file.
 *
 * Where U-Boot loads it: the copy overwrites 0x200000..0x700000 and the code (load address + 0x502000) has to stay outside
 * that range. The boot script loads the file at 0xa000000, far from it, and text_offset in the header says the same, so a
 * U-Boot that relocates the image (booti variants that do not honour the "placement anywhere" flag move it to RAM base +
 * text_offset) puts it at the same place. The default kernel_addr_r of common U-Boot environments (0x00400000) would put the
 * file on top of the destination; the forward copy happens to cope with that, but there is no reason to depend on it.
 *
 * FV_ENTRY_OFFSET (set by build.sh, from tools/stub/fv-entry.py) is the entry of the volume's SEC module, counted from the
 * start of the volume. It is 0x1400 for the volumes this repository builds.
 */

#ifndef FV_ENTRY_OFFSET
#error "FV_ENTRY_OFFSET is not defined: build with tools/stub/build.sh (it reads the offset from the volume)"
#endif

#ifndef LAUNCHER_WDT
#define LAUNCHER_WDT	1		/* 1 = arm the hardware watchdog before entering the firmware */
#endif

#define STR_(x)		#x
#define STR(x)		STR_(x)

#define UART_BASE	0xfeb50000	/* UART2, the debug console, already set up by U-Boot (1500000 8N1) */
#define UART_THR	0x00
#define UART_LSR	0x14
#define LSR_THRE	0x20

	.section .text.head, "ax"
	.globl _head
_head:
	b	_stub			/* code0 */
	.long	0			/* code1 */
	.quad	0xa000000		/* text_offset: where the boot script loads the file; a booti that moves the image to
					 * RAM base + text_offset instead of keeping it in place lands on the same address */
	.quad	_end			/* image_size */
	.quad	0xa			/* flags: little endian, 4 KiB pages, placement anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _stub
_stub:
	msr	daifset, #0xf
	mov	x19, x0			/* the device tree from U-Boot; saved to TPIDRRO_EL0 below */

	adr	x0, msg_el
	bl	puts
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	bl	puthex
	adr	x0, msg_copy
	bl	puts

	/* Copy the volume to 0x200000. The source is the load address + 0x2000, always above 0x700000 here, so the destination
	 * is below the source and the copy has to go forward (the memmove rule: forward is safe when dst < src).
	 *
	 * adr reaches only +-1 MiB, and the volume is 0x500000 below this code, so the source is computed as "address of the
	 * stub - 0x500000": sub can encode 0x500000 as imm12 << 12. */
	adr	x20, _stub
	sub	x20, x20, #0x500000
	ldr	x21, =_fv_size
	movz	x22, #0x20, lsl #16	/* 0x200000 */
1:	cbz	x21, 2f
	ldr	x4, [x20], #8
	str	x4, [x22], #8
	sub	x21, x21, #8
	b	1b
2:
	/* The variable store of the volume (flash offset 0x7C0000..0x7F0000, same physical address) is zeroed. In the normal
	 * flash flow it is a separate section of the FIT; here it has no content, and edk2 treats a zeroed store as empty and
	 * initialises it. That is better than reading whatever the memory held before. */
	movz	x1, #0x7c, lsl #16
	movz	x2, #0x7f, lsl #16
10:	cmp	x1, x2
	b.hs	11f
	str	xzr, [x1], #8
	b	10b
11:
#if LAUNCHER_WDT
	/* Hardware watchdog, armed before the firmware. The board has no remote power control, so a hang in SEC/PEI/early DXE
	 * would leave it stuck until someone resets it. After arming, the board resets if nobody feeds the watchdog within about
	 * 89 s and goes back to U-Boot; UniXNUBootWdtDxe feeds it from DXE on. The register sequence is the one verified on the
	 * RK3588 EVB10: CR=0, TORR=0xf, CRR=0x76, CR=0x9 (without the CRR write the enable does not take effect). It cannot be
	 * disabled once armed. DW WDT of the RK3588 is at 0xfeaf0000. */
	movz	x1, #0xfeaf, lsl #16
	str	wzr, [x1, #0x00]		/* CR   = 0 */
	mov	w2, #0xf
	str	w2, [x1, #0x04]			/* TORR = 0xf, the longest period */
	mov	w2, #0x76
	str	w2, [x1, #0x0c]			/* CRR  = 0x76, restart the counter */
	mov	w2, #0x9
	str	w2, [x1, #0x00]			/* CR   = EN | RPL 2 */
	adr	x0, msg_wdt
	bl	puts
#else
	adr	x0, msg_nowdt
	bl	puts
#endif
	adr	x0, msg_jump
	bl	puts

	/* The device tree address from U-Boot. PeilessSec sets TPIDRRO_EL0 only when it gets a TransferList, which a start from
	 * U-Boot never has, so the address is put there here; UniXNURamDiskDxe reads it in DXE to find the payload. */
	msr	tpidrro_el0, x19

	/* Enter the SEC module with the BL33 register convention: x0 = device tree, x1..x3 = 0 */
	mov	x0, x19
	mov	x1, #0
	mov	x2, #0
	mov	x3, #0
	movz	x4, #0x20, lsl #16	/* 0x200000 */
	movk	x4, #FV_ENTRY_OFFSET
	br	x4

/* ---- polled 16550 output (U-Boot has set the UART up) ---- */
puts:
	mov	x9, x0
3:	ldrb	w10, [x9], #1
	cbz	w10, 5f
	movz	x11, #(UART_BASE & 0xffff)
	movk	x11, #(UART_BASE >> 16), lsl #16
4:	ldrb	w12, [x11, #UART_LSR]
	tst	w12, #LSR_THRE
	b.eq	4b
	strb	w10, [x11, #UART_THR]
	b	3b
5:	ret

puthex:
	mov	x9, x0
	mov	x10, #4
6:	lsr	x11, x9, x10
	and	x11, x11, #0xf
	cmp	x11, #10
	b.lo	7f
	add	x11, x11, #('a' - 10)
	b	8f
7:	add	x11, x11, #'0'
8:	movz	x12, #(UART_BASE & 0xffff)
	movk	x12, #(UART_BASE >> 16), lsl #16
9:	ldrb	w13, [x12, #UART_LSR]
	tst	w13, #LSR_THRE
	b.eq	9b
	strb	w11, [x12, #UART_THR]
	subs	x10, x10, #4
	b.pl	6b
	ret

msg_el:		.asciz	"\r\nLAUNCHER: EL="
msg_copy:	.asciz	" copying the firmware volume to 0x200000\r\n"
msg_jump:	.ascii	"LAUNCHER: jumping to 0x200000 + "
		.ascii	STR(FV_ENTRY_OFFSET)
		.asciz	"\r\n"
#if LAUNCHER_WDT
msg_wdt:	.asciz	"LAUNCHER: DW WDT 0xfeaf0000 armed (TORR 0xf), UniXNUBootWdtDxe takes over feeding\r\n"
#else
msg_nowdt:	.asciz	"LAUNCHER: DW WDT NOT armed (LAUNCHER_WDT=0)\r\n"
#endif

	.section .fv, "a"
	.balign	8
	.globl _fv_start
_fv_start:
	.incbin	"fv.bin"
_fv_end:

	.set	_fv_size, (_fv_end - _fv_start)
