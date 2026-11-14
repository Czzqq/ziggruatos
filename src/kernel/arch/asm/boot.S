#include <constants.h>

.section ".text.boot"

.globl _start
_start:
#if !KERNEL_LINEAR_IMAGE
    /* load text section from LMA to VMA */
    la t0, TEXT_ROM
    la t1, stext
    la t2, etext
.L0:
    ld a5, (t0)
    sd a5, (t1)
    addi t1, t1, 8
    addi t0, t0, 8
    bltu t1, t2, .L0
#endif
    /* disable s-mode interrupt */
    csrw sie, zero

    /* hart 0: tp = 0 */
    li tp, 0

    /* hart 0 uses boot_stacks[0]: sp = boot_stacks + 1 * KERNEL_STACK_SIZE */
    la sp, boot_stacks
    li t0, KERNEL_STACK_SIZE
    add sp, sp, t0

    /* jump zig kmain */
    tail kmain

/*
 * Secondary hart entry point.
 *
 * Called via SBI HSM hart_start(hartid, start_addr, opaque).
 * a0 = hartid, a1 = opaque (unused).
 *
 * Each secondary hart:
 *   1. Sets tp = hartid (for PerCpu.currentCpu())
 *   2. Sets up its own stack from boot_stacks[hartid]
 *   3. Jumps to kmain_secondary
 */
.globl _start_secondary
_start_secondary:
    /* a0 contains hartid from SBI */
    mv tp, a0

    /* Calculate stack pointer: sp = boot_stacks + (hartid + 1) * KERNEL_STACK_SIZE */
    la sp, boot_stacks
    li t0, KERNEL_STACK_SIZE
    addi t1, a0, 1          /* hartid + 1 */
    mul t0, t0, t1          /* KERNEL_STACK_SIZE * (hartid + 1) */
    add sp, sp, t0

    /* disable s-mode interrupt */
    csrw sie, zero

    /* jump zig kmain_secondary */
    tail kmain_secondary

/*
 * Per-hart boot stacks.
 *
 * Layout: hart 0 uses boot_stacks[0], hart 1 uses boot_stacks[1], etc.
 * Each stack is KERNEL_STACK_SIZE bytes (64 KiB).  Stacks live in .bss
 * so they are zero-initialised at load and consume no image space.
 * The linker places .bss.stack before sbss, so clearBss() does not touch them.
 */
.section .bss.stack
.align  4
.global boot_stacks
boot_stacks:
    .skip KERNEL_STACK_SIZE * MAX_CPUS

.section  .rodata
.align 3
.globl boot_string
boot_string:
       .string "Booting at asm\n"
