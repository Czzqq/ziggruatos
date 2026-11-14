# Rust 用户程序框架

## 职责与执行环境

MMU 目标的 Rust 应用运行在 U-mode，使用 `no_std`，由共享的 ziggurat_core 提供入口、固定堆、系统调用和基本文件/输出接口。内核负责 ELF 加载、地址空间与进程生命周期；库不包含主机 Rust 标准库的操作系统适配层。

入口初始化 32 KiB 静态堆，将内核传递的 argc/argv 转为字符串参数，调用应用 main，再通过 exit 结束进程。应用必须遵守内核的参数布局、字符串终止与 ELF 约定；这些不是 Linux ABI 兼容承诺。

## 启动程序与 shell

内核初始 initcode exec `/init`，init 再启动 shell。shell 组织命令执行和子进程等待，`cd` 和 `pwd` 是内建命令。用户程序包括 ls、cat、echo、mkdir、touch、rm、sleep、smpdemo 和 syscheck。完整管道、重定向、作业控制及信号处理仍未完成。

程序从 VFS 获取文件和设备服务。构建好的 ELF 进入 initramfs；ZFS 根缺少相应顶层文件时可通过只读回退节点访问。磁盘已有旧程序优先，因此重新构建不保证覆盖旧磁盘程序。

## 构建与资源边界

Cargo 工作区面向 `riscv64imac-unknown-none-elf`，链接脚本规定入口和段布局；用户 Makefile发现应用包并复制构建输出，顶层 Zig 构建图将它接入 initramfs。入口和 panic/alloc 错误处理依赖 nightly 特性。

用户堆容量固定，sbrk 尚未分发；分配失败进入错误处理。fork 复制地址空间，不提供线程共享堆。读写必须处理失败和 EOF，不假设一次调用完成任意长度传输。

原生 DuoS 小核不构建或运行这些 ELF；小核交互 shell 是 M-mode 内核任务。

实现依据：`src/user/lib/ziggurat_core/src/lib.rs`、`src/user/Makefile`、`src/user/linker.ld`、`src/user/bin/`。相关：[syscall 封装](2-Syscall-Wrapper.md)、[运行库支持](3-Standard-Library-Support.md)。
