# 系统调用接口

## 约定与实现依据

用户程序运行在 **U-mode**，通过 `ecall` 进入 S-mode 内核。Rust 封装位于 `src/user/lib/ziggurat_core/src/syscall.rs`，内核实际分发位于 `src/kernel/syscall.zig` 的 `trapSyscallHandler()`。以下状态以当前工作树的实际分发为准。

| 寄存器 | 用途 |
|--------|------|
| a7 | 系统调用号 |
| a0 | 参数 0 / 返回值 |
| a1..a5 | 后续参数（当前 Rust 通用封装传 a0..a2） |

`argraw()` 从当前任务 trapframe 取参数；`argint()`、`argaddr()`、`argstr()` 处理具体类型。涉及用户内存时，使用页表的 `copyIn`、`copyOut`、`copyInStr` 等函数。许多失败路径返回按 u64 位模式保存的 `-1`，用户封装按 `isize` 读取；当前没有统一的 POSIX errno 返回体系。

## 已接入内核分发的调用

| 号 | 名称 | 参数 / 行为 |
|----|------|-------------|
| 1 | fork | 复制进程；父进程得到子 PID，子进程得到 0 |
| 2 | exit | 退出码；释放资源并进入 zombie 状态 |
| 3 | wait | 用户退出状态地址；等待并回收子进程 |
| 5 | read | fd、用户缓冲区、长度 |
| 6 | kill | pid；设置任务 killed 标记，不是完整信号机制 |
| 7 | exec | 路径、以 NULL 结尾的 argv 指针数组 |
| 9 | chdir | 路径 |
| 11 | getpid | 当前 PID |
| 13 | sleep | ticks；等待共享 jiffies 推进 |
| 15 | open | 路径、标志 |
| 16 | write | fd、用户缓冲区、长度 |
| 17 | mknod | 路径、mode、设备号 |
| 18 | unlink | 路径 |
| 20 | mkdir | 路径（Rust 接口另传 mode，内核使用固定权限） |
| 21 | close | fd |
| 22 | console | fd、缓冲区、长度 |
| 23 | readdir | 路径、目录项缓冲区、缓冲区字节数 |
| 24 | getcwd | 缓冲区、大小；成功返回用户缓冲区地址 |
| 25 | getcpu | 返回本次系统调用执行时的 hart ID |

## 已定义但未分发的调用

| 号 | 名称 |
|----|------|
| 4 | pipe |
| 8 | fstat |
| 10 | dup |
| 12 | sbrk |
| 14 | uptime |
| 19 | link |

上述编号存在于枚举/常量中，但没有实际处理分支。内核对未分发的编号返回专用错误码 `-38`（ENOSYS），Rust 对应包装函数将它转换为 `SyscallError::NotImplemented`。普通调用失败仍可能返回 `-1`，不应把它当作「未实现」。`syscheck` 会实际调用这六项，只有收到 `NotImplemented` 才标记 SKIP；收到别的错误或意外成功会 FAIL。完整管道、重定向及用户堆扩展仍未实现。

## getcpu 与 SMP 观察

内核读取当前 tp 中的 hart ID 并返回。tp 用于索引 PerCpu。

这是采样值，不设置 CPU 亲和性。进程可能在之后的调度中迁移。`smpdemo` 创建两个计算型子进程，每轮调用 `getcpu` 并汇总观察到的 hart 掩码。

## 进程与时间语义

- `fork` 复制地址空间、trapframe，并继承文件指针和 cwd、增加引用计数；尚未实现 COW。
- `exec` 从 VFS 查找 ELF、构造新地址空间并传递参数。初始任务通过内嵌 initcode 发起此调用。
- `exit` 设置 zombie 状态；`wait` 使用 `wait_lock`、`task_list_lock` 和任务锁保护等待及回收路径。
- `sleep` 在 `ticks_lock` 保护下等待 `jiffies` 差值，并通过 `proc.sleep()` 让出 CPU。多个 hart 的时钟中断都更新共享 jiffies；ticks 不能直接当作墙钟秒数。

相关说明：[进程](2-Process-and-Scheduling.md)、[启动](6-Boot-and-Initialization-Flow.md)、[Rust 封装](../Userland-Implementation-Rust/2-Syscall-Wrapper.md)。
