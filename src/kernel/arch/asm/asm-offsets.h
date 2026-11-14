#ifndef __ASM_OFFSETS_H__
#define __ASM_OFFSETS_H__

/*
 * x0 : zero
 * x1 : ra
 * x2 : sp
 * x3 : gp
 * x4 : tp
 * x5 ~ x7 .. x28 ~ x31 : t0 ~ t6
 * x8 : s0/fp
 * x9 : s1
 * x10 ~ x17 : a0 ~ a7
 * x18 ~ x27: s2 ~ s11
 */

#define TF_SIZE  320 /* sizeof(trapFrame) */

#define TF_KERNEL_SATP 0 /* offsetOf(trapFrame, kernel_sapt) */
#define TF_KERNEL_SP 8 /* offsetOf(trapFrame, kernel_sp) */
#define TF_KERNEL_TRAP 16 /* offsetOf(trapFrame, kernel_trap) */
#define TF_KERNEL_HARTID 24 /* offsetOf(trapFrame, kernel_hartid) */

#define TF_SEPC 32 /* offsetof(trapFrame, sepc) */
#define TF_RA 40 /* offsetof(trapFrame, ra) */
#define TF_SP 48 /* offsetof(trapFrame, sp) */
#define TF_GP 56 /* offsetof(trapFrame, gp) */
#define TF_TP 64 /* offsetof(trapFrame, tp) */
#define TF_T0 72 /* offsetof(trapFrame, t0) */
#define TF_T1 80 /* offsetof(trapFrame, t1) */
#define TF_T2 88 /* offsetof(trapFrame, t2) */
#define TF_S0 96 /* offsetof(trapFrame, s0) */
#define TF_S1 104 /* offsetof(trapFrame, s1) */
#define TF_A0 112 /* offsetof(trapFrame, a0) */
#define TF_A1 120 /* offsetof(trapFrame, a1) */
#define TF_A2 128 /* offsetof(trapFrame, a2) */
#define TF_A3 136 /* offsetof(trapFrame, a3) */
#define TF_A4 144 /* offsetof(trapFrame, a4) */
#define TF_A5 152 /* offsetof(trapFrame, a5) */
#define TF_A6 160 /* offsetof(trapFrame, a6) */
#define TF_A7 168 /* offsetof(trapFrame, a7) */
#define TF_S2 176 /* offsetof(trapFrame, s2) */
#define TF_S3 184 /* offsetof(trapFrame, s3) */
#define TF_S4 192 /* offsetof(trapFrame, s4) */
#define TF_S5 200 /* offsetof(trapFrame, s5) */
#define TF_S6 208 /* offsetof(trapFrame, s6) */
#define TF_S7 216 /* offsetof(trapFrame, s7) */
#define TF_S8 224 /* offsetof(trapFrame, s8) */
#define TF_S9 232 /* offsetof(trapFrame, s9) */
#define TF_S10 240 /* offsetof(trapFrame, s10) */
#define TF_S11 248 /* offsetof(trapFrame, s11) */
#define TF_T3 256 /* offsetof(trapFrame, t3) */
#define TF_T4 264 /* offsetof(trapFrame, t4) */
#define TF_T5 272 /* offsetof(trapFrame, t5) */
#define TF_T6 280 /* offsetof(trapFrame, t6) */
#define TF_SSTATUS 288 /* offsetof(trapFrame, sstatus) */
#define TF_SBADADDR 296 /* offsetof(trapFrame, sbadaddr) */
#define TF_SCAUSE  304 /* offsetof(trapFrame, scause) */
#define TF_ORIG_A0 312 /* offsetof(trapFrame, orig_a0) */

#endif
