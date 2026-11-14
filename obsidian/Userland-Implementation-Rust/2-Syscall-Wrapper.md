# Rust 系统调用封装

## 职责与 ABI

syscall 模块将 Rust 调用转换为 RISC-V ecall，并把内核返回值转换为应用可用的结果。当前通用封装传递 a0..a2 三个参数，a7 存编号，a0 返回结果。内核参数提取支持 a0..a5，但这不表示当前 Rust 通用封装提供六参数接口。

路径和字符串需要满足内核的用户地址及终止约定；exec 需要构造以空指针结尾的 argv。封装负责准备参数，内核仍必须通过用户页表复制和校验，不能依赖 Rust 类型排除非法用户地址。

## 可用能力与错误

实际编号、处理分支及参数契约集中于 [系统调用接口](../System-Design/5-Syscall-Interface.md)。接口枚举中存在某编号不代表内核支持。pipe、fstat、dup、sbrk、uptime、link 当前没有处理分支，返回 `-38`；对应 Result 封装映射为 NotImplemented。

多数已实现调用失败仍使用 `-1`，部分接口直接返回 isize，当前不是完整 POSIX errno 体系。应用需按具体封装检查负值或 Result，不应把所有失败统称为未实现。syscheck 实际调用未实现项，只有专用错误才记 SKIP。

## 文件与控制台抽象

file 模块的 File 持有描述符，Drop 关闭资源，显式 close 避免析构重复关闭。文件创建组合创建、只写、截断标志。读写返回传输字节数，调用者需要处理短读写和 EOF。

Stdin/Stdout 提供基本输入输出，格式化输出借助 core::fmt。它们是本项目运行库的封装，不等价于 Rust std::io 的完整 trait 和错误语义。

## 观察与时间

getcpu 返回 syscall 执行位置的 hart ID，不能固定进程到某 CPU。sleep 的参数为 ticks，当前多 hart 都推进共享计数；不能按墙钟秒数解释。kill 设置内核 killed 状态，不是通用信号发送接口。

实现依据：`src/user/lib/ziggurat_core/src/syscall.rs`、`file.rs`、`console.rs` 和 `src/kernel/syscall.zig`。验证见 [syscheck](../../docs/SYSCHECK.md)。
