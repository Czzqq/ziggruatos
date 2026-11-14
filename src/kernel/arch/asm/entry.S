#include "asm-offsets.h"

.macro kernel_entry
	addi sp, sp, -(TF_SIZE)

	sd x1,  TF_RA(sp)
	sd x3,  TF_GP(sp)
	sd x5,  TF_T0(sp)
	sd x4,  TF_TP(sp)
	sd x6,  TF_T1(sp)
	sd x7,  TF_T2(sp)
	sd x8,  TF_S0(sp)
	sd x9,  TF_S1(sp)
	sd x10, TF_A0(sp)
	sd x11, TF_A1(sp)
	sd x12, TF_A2(sp)
	sd x13, TF_A3(sp)
	sd x14, TF_A4(sp)
	sd x15, TF_A5(sp)
	sd x16, TF_A6(sp)
	sd x17, TF_A7(sp)
	sd x18, TF_S2(sp)
	sd x19, TF_S3(sp)
	sd x20, TF_S4(sp)
	sd x21, TF_S5(sp)
	sd x22, TF_S6(sp)
	sd x23, TF_S7(sp)
	sd x24, TF_S8(sp)
	sd x25, TF_S9(sp)
	sd x26, TF_S10(sp)
	sd x27, TF_S11(sp)
	sd x28, TF_T3(sp)
	sd x29, TF_T4(sp)
	sd x30, TF_T5(sp)
	sd x31, TF_T6(sp)

	csrr s1, sstatus
	sd s1, TF_SSTATUS(sp)

	/*save sepc*/
	csrr s2, sepc
	sd s2, TF_SEPC(sp)

	/*save sbadaddr*/
	csrr s3, stval
	sd s3, TF_SBADADDR(sp)

	/*save scause*/
	csrr s4, scause
	sd s4, TF_SCAUSE(sp)

	/*save SP*/
	addi s0, sp, TF_SIZE
	sd s0, TF_SP(sp)
.endm

.macro kernel_exit
	ld a0, TF_SSTATUS(sp)
	csrw sstatus, a0

	ld a2, TF_SEPC(sp)
	csrw sepc, a2

	ld x1,  TF_RA(sp)
	ld x3,  TF_GP(sp)
	ld x4,  TF_TP(sp)
	ld x5,  TF_T0(sp)
	ld x6,  TF_T1(sp)
	ld x7,  TF_T2(sp)
	ld x8,  TF_S0(sp)
	ld x9,  TF_S1(sp)
	ld x10, TF_A0(sp)
	ld x11, TF_A1(sp)
	ld x12, TF_A2(sp)
	ld x13, TF_A3(sp)
	ld x14, TF_A4(sp)
	ld x15, TF_A5(sp)
	ld x16, TF_A6(sp)
	ld x17, TF_A7(sp)
	ld x18, TF_S2(sp)
	ld x19, TF_S3(sp)
	ld x20, TF_S4(sp)
	ld x21, TF_S5(sp)
	ld x22, TF_S6(sp)
	ld x23, TF_S7(sp)
	ld x24, TF_S8(sp)
	ld x25, TF_S9(sp)
	ld x26, TF_S10(sp)
	ld x27, TF_S11(sp)
	ld x28, TF_T3(sp)
	ld x29, TF_T4(sp)
	ld x30, TF_T5(sp)
	ld x31, TF_T6(sp)

	ld x2,  TF_SP(sp)
.endm

/*
 * do_exception_vector must align 4 bytes
 */
ret_from_exception:
recover_all:
    kernel_exit

    sret

.align 4
.global doKernelExceptionVector
doKernelExceptionVector:
    kernel_entry

	csrw sscratch, x0
    /* set return from exception symbol address */
    la ra, ret_from_exception

    /* trapFrame */
    mv a0, sp
    mv a1, s4
    tail do_exception


/*
 * test: fot test fault trigger
 */
.align 2
.global trigger_fault
trigger_fault:
    # set a vaild sp
    addi sp, sp, -16
    sd ra, TF_RA(sp)
    sd s0, TF_SP(sp)
    addi s0, sp, 16

    # try to access a error address
    li a0, 0x0
    ld a1, (a0) # trap!!!

    # it's not normal to process it
    li a0, -1
    sd a0, TF_SSTATUS(sp)

    ld ra, TF_RA(sp)
    ld s0, TF_SP(sp)
    addi sp, sp, 16
    ret
