#include "asm-offsets.h"
#include "constants.h"

.section trampsec
.globl trampoline
.globl usertrap
trampoline:
.align 4
.globl uservec
uservec:
    /*
     * stvec point here, traps from user space start here,
     * in supervisor mode, but with a user page table
     */
    /*
     * save user a0 in sscratch,
     * a0 used to get at TRAPFRAME
     */
    csrw sscratch, a0

    li a0, TRAPFRAME
    // save regs to p->trapframe memory area
    sd ra, TF_RA(a0)
    sd sp, TF_SP(a0)
    sd gp, TF_GP(a0)
    sd tp, TF_TP(a0)
    sd t0, TF_T0(a0)
    sd t1, TF_T1(a0)
    sd t2, TF_T2(a0)
    sd s0, TF_S0(a0)
    sd s1, TF_S1(a0)
    sd a1, TF_A1(a0)
    sd a2, TF_A2(a0)
    sd a3, TF_A3(a0)
    sd a4, TF_A4(a0)
    sd a5, TF_A5(a0)
    sd a6, TF_A6(a0)
    sd a7, TF_A7(a0)
    sd s2, TF_S2(a0)
    sd s3, TF_S3(a0)
    sd s4, TF_S4(a0)
    sd s5, TF_S5(a0)
    sd s6, TF_S6(a0)
    sd s7, TF_S7(a0)
    sd s8, TF_S8(a0)
    sd s9, TF_S9(a0)
    sd s10, TF_S10(a0)
    sd s11, TF_S11(a0)
    sd t3, TF_T3(a0)
    sd t4, TF_T4(a0)
    sd t5, TF_T5(a0)
    sd t6, TF_T6(a0)

    // save user a0 in p->trapframe->a0
    csrr t0, sscratch
    sd t0, TF_A0(a0)
    sd t0, TF_ORIG_A0(a0)

    // Snapshot the trap CSRs while TRAPFRAME is still addressable through
    // the user page table. usertrap() consumes this snapshot after switching
    // to the kernel page table.
    csrr t0, sstatus
    sd t0, TF_SSTATUS(a0)
    csrr t0, sepc
    sd t0, TF_SEPC(a0)
    csrr t0, stval
    sd t0, TF_SBADADDR(a0)
    csrr t0, scause
    sd t0, TF_SCAUSE(a0)

    // initialize kernel stack pointer, p->trapframe->kernel_sp
    ld sp, TF_KERNEL_SP(a0)

    // make tp hold the current hartid, p->trapframe->kernel_hartid
    ld tp, TF_KERNEL_HARTID(a0)

    // load the address of usertrap()
    ld t0, TF_KERNEL_TRAP(a0)

    // load the address of usertrap, p->trapframe->kernel_trap
    ld t1, TF_KERNEL_SATP(a0)

    sfence.vma zero, zero

    // install the kernel page table
    csrw satp, t1

    sfence.vma zero, zero

    csrw sscratch, zero

    // jump to usertrap()
    jr t0

.globl userret
userret:
    // switch from kernel to user
    // a0: user page table, for satp

    // swtich to user page table
    sfence.vma zero, zero
    csrw satp, a0
    sfence.vma zero, zero

    li a0, TRAPFRAME

    // restore all but a0 from TRAPFRAME
    ld ra, TF_RA(a0)
    ld sp, TF_SP(a0)
    ld gp, TF_GP(a0)
    ld tp, TF_TP(a0)
    ld t0, TF_T0(a0)
    ld t1, TF_T1(a0)
    ld t2, TF_T2(a0)
    ld s0, TF_S0(a0)
    ld s1, TF_S1(a0)
    ld a1, TF_A1(a0)
    ld a2, TF_A2(a0)
    ld a3, TF_A3(a0)
    ld a4, TF_A4(a0)
    ld a5, TF_A5(a0)
    ld a6, TF_A6(a0)
    ld a7, TF_A7(a0)
    ld s2, TF_S2(a0)
    ld s3, TF_S3(a0)
    ld s4, TF_S4(a0)
    ld s5, TF_S5(a0)
    ld s6, TF_S6(a0)
    ld s7, TF_S7(a0)
    ld s8, TF_S8(a0)
    ld s9, TF_S9(a0)
    ld s10, TF_S10(a0)
    ld s11, TF_S11(a0)
    ld t3, TF_T3(a0)
    ld t4, TF_T4(a0)
    ld t5, TF_T5(a0)
    ld t6, TF_T6(a0)

    // restore user 'a0'
    ld a0, TF_A0(a0)

    // return to user mode and user pc
    sret
