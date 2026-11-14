# 系统架构总览

## 职责分层

ZigguratOS 的 MMU 目标采用单体内核。SBI 固件提供机器级服务；S-mode 内核统一管理内存、调度、文件系统和设备；Rust U-mode 应用通过系统调用进入内核。模块分离通过 Zig 构建模块及显式依赖实现，内核服务仍共享特权地址空间。

| 模块 | 责任 | 边界 |
| --- | --- | --- |
| board / platform | 描述板级地址、CPU 数、UART 与定时器，探测块设备 | 硬件选择不进入文件系统策略 |
| arch | CSR、SBI、锁、PerCpu 与架构操作 | 提供机制，不负责用户进程生命周期 |
| common | 地址类型、ELF 与公共日志接口 | 日志依赖通过初始化安装 |
| memory / pagetable | 分配物理资源、内核堆与地址空间映射 | 用户复制必须遵守页表权限 |
| task / trap / syscall | 进程生命周期、执行切换与用户服务入口 | 系统调用编号不代表已有实现 |
| device / drivers / block | 设备身份、硬件协议、块读写与缓存 | 驱动通过初始化参数获得服务，避免反向导入内核 |
| fs | VFS、后端与启动填充策略 | 不直接决定板级硬件探测 |

## 协作方式

启动阶段先建立内存与设备基础，再由平台探测提供块设备。文件系统启动策略选择根后端，VFS 接管路径与挂载，devfs 将已注册设备暴露到 `/dev`。创建首个用户任务后才启动其他 hart，避免调度器看到未发布的共享状态。

运行时，用户请求经 trap 保存现场，由 syscall 分发到任务或 VFS 服务；VFS 再调用具体后端。ZFS 通过 block 层访问驱动，tmpfs 只使用内存。时钟中断驱动调度和睡眠唤醒。

## 平台差异

QEMU virt 使用两 hart、外部 initramfs 和 VirtIO 块设备。DuoS 大核使用单 hart、嵌入式 initramfs 和 DW APB UART，板级构建使用 tmpfs。

DuoS 小核是另一种执行模型：C906L 没有 MMU，原生 M-mode 入口运行共享内存的内核任务。它复用物理分配、VFS 和设备抽象，但不执行 U-mode ELF、fork/exec 或现有 syscall ABI，不能将 MMU 内核能力直接套用。

## 设计取舍与限制

单体内核便于观察完整调用链，但模块之间缺少进程级故障隔离。MMU 用户进程各有页表，内核主体采用物理区域恒等映射。基础 SMP 已有分配器和任务路径锁；这不构成 VFS/ZFS 多步骤事务安全或跨 hart TLB 同步的证明。TEE、可信启动和虚拟化尚是学习规划。

继续阅读：[启动](6-Boot-and-Initialization-Flow.md)、[进程](2-Process-and-Scheduling.md)、[内存](3-Memory-Management-Design.md)、[VFS](4-Virtual-File-System.md)。
