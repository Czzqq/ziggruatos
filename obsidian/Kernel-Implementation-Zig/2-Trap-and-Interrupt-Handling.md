# 陷阱与中断处理

## 职责与边界

MMU trap 模块连接汇编入口、进程现场和内核分发。同步异常由当前指令触发，外部中断和时钟中断来自设备或定时器；系统调用是有意执行的用户 ecall，不能把所有 trap 统一当错误处理。

用户 trapframe 保存通用寄存器、返回 PC 和返回内核所需的元数据。其布局必须与汇编保存/恢复约定一致；内核上下文切换保存的是任务内核执行续点，两种现场不能互相替代。

## 用户进入与返回

用户执行 ecall 或触发异常后，trampoline 保存用户寄存器，恢复内核栈、hart 身份和页表，然后进入 Zig 处理逻辑。trampoline 在页表切换前后具有稳定虚拟地址，避免切换时失去当前执行映射。

ecall 分支推进返回 PC，交给 syscall 分发，并把结果写回 a0。返回用户态前准备 trapframe 中的内核元数据和返回状态，切换用户页表，恢复寄存器，再执行特权返回。被 kill 的任务或不可恢复用户异常需要退出，不应无限重试原故障指令。

## 内核中断

内核 trap 入口保存被中断的内核现场。外部中断通过 PLIC claim/complete 协议路由；UART 输入由串口逻辑消费。时钟事件重设下一次 SBI 定时器，推进共享 ticks、唤醒等待者，并在适当任务上下文触发调度。

初始化每个 hart 的陷阱向量和定时器是启动该 hart 的必要步骤。共享计数更新需要锁，单 hart 中断关闭无法保护其他 hart 的访问。

## 原生小核差异

小核使用独立 M-mode 汇编入口，保存完整整数现场，由本地 CLINT 驱动固定内核任务轮转；UART 输入按 tick 轮询，不设置共享 PLIC。发生机器异常时保存故障记录并停机。这里没有 U-mode syscall 返回或 Sv39 trampoline 切换。

实现依据：`src/kernel/trap.zig`、`src/kernel/arch/asm/trampoline.S`、`src/kernel/arch/asm/entry.S`、`src/kernel/timer.zig` 及小核 board 实现。相关：[进程](../System-Design/2-Process-and-Scheduling.md)、[系统调用](../System-Design/5-Syscall-Interface.md)。
