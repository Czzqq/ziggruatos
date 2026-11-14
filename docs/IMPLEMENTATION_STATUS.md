# 当前实现范围

本文依据当前源码与构建配置描述能力，和 [文档审查记录](DOCUMENTATION_AUDIT.md) 配合使用。它不是本轮 QEMU 或硬件测试通过证明。

## 平台模型

| 平台 | 已接入实现 | 主要限制 |
| --- | --- | --- |
| QEMU virt | S-mode、Sv39、两 hart、Rust 用户程序、VirtIO、ZFS/tmpfs | 完整存储并发与跨 hart TLB 同步仍需完善 |
| DuoS 大核 | 单 hart S-mode、C906 PTE 属性、DW APB UART、嵌入式 initramfs、FIP 打包 | 默认 tmpfs；未提供板上块、USB、网络等驱动 |
| DuoS 小核 | 无 MMU 的 M-mode 内核任务、CLINT 抢占、UART1、物理分配、tmpfs/devfs | 共享内存，无现有 U-mode ELF/syscall；需 Linux 排除保留内存和设备 |

## 服务与边界

- 内存：位图物理页、连续页、内核堆及 MMU 页表已接入。物理分配器、堆、任务栈路径有锁。跨 hart shootdown 尚未完整实现。
- 进程：fork 复制地址空间，exec 加载 ELF，exit/wait 回收，基本共享队列调度已接入。没有 COW、CPU 亲和性或完整信号体系。
- 系统调用：实际分发表见 [ABI](../obsidian/System-Design/5-Syscall-Interface.md)。pipe/fstat/dup/sbrk/uptime/link 返回 `-38`；接口编号不能作为实现证明。
- 文件系统：tmpfs 与 ZFS 根可选，`/dev` 挂载 devfs。ZFS 挂载失败回 tmpfs；缺块设备不保证回退。initramfs 在 ZFS 下补充缺失顶层文件，已有磁盘内容优先。
- 存储：ZFS v2 支持 12 直接块与单级间接块，文件上限 4,243,456 字节。block 句柄读写有锁与写穿缓存，VirtIO 全局缓冲复用和 VFS/ZFS 多步状态仍有并发边界；sync 还有已登记实现风险。
- 用户运行库：固定 32 KiB 堆，非动态 sbrk 扩堆；提供基本文件和控制台封装，没有完整 std 或用户线程。
- 时间：MMU sleep 使用 ticks，多 hart 更新共享 jiffies，不等价墙钟秒数；原生小核的本地 1 kHz 调度路径是独立实现。

## 构建与验证方法

Zig 构建图负责配置、汇编常量生成、用户程序、initramfs、内核与磁盘步骤。Makefile 转发配置并启动 QEMU/GDB。默认 ZFS、磁盘 10 MiB、复制用户程序；普通构建不格式化镜像，显式 disk 步骤会格式化。

当前开发环境工具版本与命令见 [README](../README.md)。自动化 syscall 验证见 [syscheck](SYSCHECK.md)，板级验收分别见 [大核](MILK_V_DUOS.md) 与 [小核](DUOS_SMALLCORE.md)。本轮文档修改只执行静态核对和链接检查，没有重新格式化磁盘、启动 QEMU 或连接硬件。

TEE、可信启动、远程证明与 hypervisor 尚属 [规划](../obsidian/Future-Features/Roadmap.md)。SBI HSM、基础 SMP、原生 M-mode 均不能作为这些里程碑完成证明。
