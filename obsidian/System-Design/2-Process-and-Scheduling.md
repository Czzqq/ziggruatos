# 进程与调度

## 模块职责

MMU 目标的 task 模块负责进程资源、状态迁移、共享任务列表以及父子关系。arch 的 PerCpu 记录当前 hart，任务侧的 CPU 状态关联当前进程和调度上下文。trap 模块保存用户寄存器，汇编上下文切换保存内核执行续点，两者服务于不同的切换边界。

## 生命周期与资源

进程拥有用户页表、trapframe、内核栈、文件描述符表和当前目录。任务内核栈使用独立映射并设置保护页，栈槽分配和映射有锁保护。

初始任务先运行映射在用户地址 0 的内嵌 initcode，再 exec `/init`；用户 init 启动 shell。`fork` 复制地址空间和用户现场，父进程得到子 PID，子进程得到 0；文件指针和 cwd 按引用共享，不是重新打开。当前没有 COW。

`exec` 从 VFS 读取 ELF，构造新的用户映射和参数栈，成功后替换原程序。`exit` 关闭进程资源、保存退出状态并成为 zombie；父进程 `wait` 读取状态后回收子任务。没有可等待子进程等错误路径应由调用者处理。

## 调度与同步

调度器从共享列表选择 ready 任务，在切换过程中将其置为 running。运行任务通过 yield、阻塞等待或时钟抢占释放 CPU。当前是面向学习的轮转选择，任务优先级字段不等于已实现优先级调度策略。

任务列表锁保护查找和变更，任务锁保护状态切换，wait 锁协调父子退出和等待。sleep 接收等待 channel 及调用者持有的锁，在建立睡眠状态时交接锁；wakeup 按 channel 查找任务。这一协议用于避免检查条件与入睡之间丢失唤醒。

QEMU virt 的两个 hart 使用同一任务集合，进程可在后续调度中迁移。`getcpu` 只采样本次执行 hart，`smpdemo` 可验证本次观察到的 hart 集合。DuoS 大核配置单 hart。

## 时间与边界

MMU `sleep` 接收 ticks，通过共享 jiffies 等待。多个 hart 都更新计数，不能将 ticks 直接解释为秒或固定墙钟毫秒。kill 是 killed 标记及相关检查，不是 POSIX 信号体系。

基本 SMP 不代表存储事务安全、CPU 亲和性、跨 hart TLB shootdown 或全面压力测试已经完成。小核的原生任务调度器是独立路径：固定 shell/worker/idle 内核任务共享 M-mode 地址空间，无 fork/exec。

实现依据：`src/kernel/task.zig`、`src/kernel/arch/cpu.zig`、`src/kernel/arch/asm/swtch.S`、`src/kernel/timer.zig`。相关：[陷阱](../Kernel-Implementation-Zig/2-Trap-and-Interrupt-Handling.md)、[系统调用](5-Syscall-Interface.md)。
