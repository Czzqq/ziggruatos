.option norvc
.option norelax
.section .text.machine.boot, "ax"
.balign 4
.globl _start
_start:
    csrw mie, zero
    li t0, 8
    csrc mstatus, t0
    csrr tp, mhartid
    bnez tp, native_park
    la sp, boot_stack_top
    la t0, native_trap
    csrw mtvec, t0
    csrw mscratch, zero
    csrw 0x7c1, zero
    li t0, 0x30013
    csrs 0x7c2, t0
    .word 0x0190000b
    fence.i
    li t0, 1
    csrw 0x7c1, t0
    li gp, 0
    la t0, sbss
    la t1, ebss
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    li t0, 0x03001064
    lw t1, 0(t0)
    andi t1, t1, -8
    ori t1, t1, 6
    sw t1, 0(t0)
    li t0, 0x03001068
    lw t1, 0(t0)
    andi t1, t1, -8
    ori t1, t1, 6
    sw t1, 0(t0)
    fence iorw, iorw
    tail native_main
native_park:
    csrw mie, zero
1:
    wfi
    j 1b

.section .text.machine, "ax"
.balign 4
.globl native_trap
native_trap:
    addi sp, sp, -272
    sd zero, 0(sp)
    sd ra, 8(sp)
    sd gp, 24(sp)
    sd tp, 32(sp)
    sd t0, 40(sp)
    sd t1, 48(sp)
    sd t2, 56(sp)
    sd s0, 64(sp)
    sd s1, 72(sp)
    sd a0, 80(sp)
    sd a1, 88(sp)
    sd a2, 96(sp)
    sd a3, 104(sp)
    sd a4, 112(sp)
    sd a5, 120(sp)
    sd a6, 128(sp)
    sd a7, 136(sp)
    sd s2, 144(sp)
    sd s3, 152(sp)
    sd s4, 160(sp)
    sd s5, 168(sp)
    sd s6, 176(sp)
    sd s7, 184(sp)
    sd s8, 192(sp)
    sd s9, 200(sp)
    sd s10, 208(sp)
    sd s11, 216(sp)
    sd t3, 224(sp)
    sd t4, 232(sp)
    sd t5, 240(sp)
    sd t6, 248(sp)
    addi t0, sp, 272
    sd t0, 16(sp)
    csrr t0, mepc
    sd t0, 256(sp)
    csrr t0, mstatus
    sd t0, 264(sp)
    mv a0, sp
    call native_dispatch
    mv sp, a0
    j native_restore
.globl native_resume
native_resume:
    mv sp, a0
native_restore:
    ld t0, 256(sp)
    csrw mepc, t0
    ld t0, 264(sp)
    csrw mstatus, t0
    ld ra, 8(sp)
    ld gp, 24(sp)
    ld tp, 32(sp)
    ld t1, 48(sp)
    ld t2, 56(sp)
    ld s0, 64(sp)
    ld s1, 72(sp)
    ld a0, 80(sp)
    ld a1, 88(sp)
    ld a2, 96(sp)
    ld a3, 104(sp)
    ld a4, 112(sp)
    ld a5, 120(sp)
    ld a6, 128(sp)
    ld a7, 136(sp)
    ld s2, 144(sp)
    ld s3, 152(sp)
    ld s4, 160(sp)
    ld s5, 168(sp)
    ld s6, 176(sp)
    ld s7, 184(sp)
    ld s8, 192(sp)
    ld s9, 200(sp)
    ld s10, 208(sp)
    ld s11, 216(sp)
    ld t3, 224(sp)
    ld t4, 232(sp)
    ld t5, 240(sp)
    ld t6, 248(sp)
    ld t0, 40(sp)
    ld sp, 16(sp)
    mret

.section .bss.stack, "aw", @nobits
.balign 16
boot_stack:
    .skip 65536
boot_stack_top:
