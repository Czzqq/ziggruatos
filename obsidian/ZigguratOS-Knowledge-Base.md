# ZigguratOS 设计知识库

文档以当前工作树实现为依据，解释模块职责、协作方式与设计限制。构建入口见 [README](../README.md)，能力状态见 [实现范围](../docs/IMPLEMENTATION_STATUS.md)。源码定位仅用于核实设计，不在文档中复制实现。

## 系统设计

| 主题 | 主要问题 |
| --- | --- |
| [架构总览](System-Design/1-System-Architecture-Overview.md) | 各层负责什么，如何装配与交互？ |
| [进程与调度](System-Design/2-Process-and-Scheduling.md) | 资源、状态、阻塞唤醒与 SMP 如何配合？ |
| [内存管理](System-Design/3-Memory-Management-Design.md) | 物理资源、堆与页表如何分工？ |
| [VFS](System-Design/4-Virtual-File-System.md) | 路径、后端、设备挂载与初始文件如何协作？ |
| [系统调用](System-Design/5-Syscall-Interface.md) | 实际 ABI、可用调用和错误语义是什么？ |
| [启动](System-Design/6-Boot-and-Initialization-Flow.md) | 何时建立共享状态与启动各 hart？ |

## 机制与运行库

| 主题 | 内容 |
| --- | --- |
| [RISC-V 支持](Kernel-Implementation-Zig/1-RISC-V-Low-Level-Support.md) | 特权级、CSR、板级参数与 CPU 身份 |
| [陷阱与中断](Kernel-Implementation-Zig/2-Trap-and-Interrupt-Handling.md) | 用户/内核现场、系统调用入口和定时抢占 |
| [设备设计](Kernel-Implementation-Zig/3-Device-Driver-Framework.md) | 注册表、驱动、块层与 devfs 的边界 |
| [用户程序](Userland-Implementation-Rust/1-User-Program-Framework.md) | no_std 入口、init、shell 与 ELF |
| [Rust syscall 封装](Userland-Implementation-Rust/2-Syscall-Wrapper.md) | 参数传递、结果转换和文件生命周期 |
| [Rust 运行库](Userland-Implementation-Rust/3-Standard-Library-Support.md) | 固定堆、集合、I/O、panic 与缺失能力 |
| [维护边界](Project-Overview/Project-Structure.md) | 模块依赖和文档归属 |

## 操作与规划

板级部署见 [DuoS 大核](../docs/MILK_V_DUOS.md) 和 [无 MMU 小核](../docs/DUOS_SMALLCORE.md)。存储机制见 [VirtIO](../docs/VIRTIO_BLOCK_DRIVER.md)，功能回归见 [syscheck](../docs/SYSCHECK.md)。

[发展方向](Future-Features/Roadmap.md) 区分当前基础能力与未来计划；TEE、安全启动和 hypervisor 未实现。原生 M-mode 小核任务共享地址空间，不等于可信执行环境。
