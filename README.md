# ZigguratOS

**Zig 内核 · Rust 用户态 · RISC-V 系统设计实验**

![Architecture](https://img.shields.io/badge/arch-RISC--V_64-555555) ![Kernel](https://img.shields.io/badge/kernel-Zig-f7a41d) ![Userland](https://img.shields.io/badge/userland-Rust_no__std-b7410e)

[快速开始](#快速开始) · [平台与能力](#平台与能力) · [开发环境](#开发环境) · [设计文档](#验证与文档)

> **AI 贡献政策**
>
> 这个仓库一开始是人类编写的，后来加入了一点 AI，现在决定完全拥抱 AI，可以任意使用 AI 进行 commit。
>
> AI 目前主要负责文档编写与维护。

ZigguratOS 是用于学习系统设计的 RISC-V 操作系统：Zig 内核负责资源管理，Rust `no_std` 程序通过系统调用使用内核服务。

## 平台与能力

| 目标 | 执行模型 | 当前边界 |
| --- | --- | --- |
| QEMU virt | SBI 固件、S-mode 内核、Sv39、U-mode 应用 | 两 hart 共享任务调度；VirtIO 块设备与 ZFS/tmpfs |
| Milk-V DuoS 大核 | C906 S-mode、Sv39、嵌入式 initramfs | 单 hart，DW APB UART；默认板级构建使用 tmpfs |
| DuoS 小核 | C906L 原生 M-mode，无 MMU | 内核任务、UART shell、tmpfs/devfs；不运行现有 Rust 用户程序 |

MMU 内核提供物理页与堆分配、进程 fork/exec/wait、定时调度、VFS、设备注册和基本 SMP。ZFS 是本项目的 Ziggurat File System，与 OpenZFS 无关。完整管道、重定向、动态用户堆扩展尚未实现；TEE 与 hypervisor 属于规划。

## 开发环境

| 工具 | 当前开发环境版本 | 用途 |
| --- | --- | --- |
| Zig | `0.18.0-dev.35+5e754304d` | 内核与构建系统 |
| QEMU | `11.0.93 (v11.1.0-rc3)` | `qemu-system-riscv64` 模拟运行 |
| Rust | nightly，未锁定精确版本 | `riscv64imac-unknown-none-elf` 用户程序 |


## 快速开始

MMU 目标使用 Zig **0.18.0-dev.35+5e754304d**、Rust nightly 和 `riscv64imac-unknown-none-elf` target；还需要 GNU Make、主机 C 编译器、Python 3、cpio。QEMU 运行需要 `qemu-system-riscv64` 和仓库中的 SBI 固件；调试需要支持 RISC-V 的 GDB。

```sh
rustup toolchain install nightly
rustup override set nightly
rustup target add riscv64imac-unknown-none-elf --toolchain nightly
make
make run
```

调试时，在一个终端启动暂停等待的 QEMU，在另一个终端连接 GDB：

```sh
# 终端 1
make debug
# 终端 2
make gdb GDB_TOOL=gdb-multiarch
```

Makefile 将构建参数转发给 `build.zig`，直接启动 QEMU/GDB，使终端信号能传给交互工具。`make run` 和 `make debug` 都配置两 hart；GDB 默认端口为 1235。从 hart 启动要求固件支持 SBI HSM。

```sh
zig build
zig build config
zig build kernel -Dplatform=virt -Dfs=tmpfs
make run FS=tmpfs
make run SBI=rustsbi
make duos
make duos-smallcore
```

构建配置来自 Zig 的 `-D` 选项，Make 对应变量包括 `PLATFORM`、`FS`、`ZFS_DISK_SIZE` 和 `COPY_TO_ZFS`。汇编常量由构建图自动生成。运行和调试使用 Make；详细板级要求见 [DuoS 大核](docs/MILK_V_DUOS.md) 与 [DuoS 小核](docs/DUOS_SMALLCORE.md)。小核原生构建只需要 Zig 和 Python，不需要 Rust 或 cpio。

## 根文件系统与磁盘

QEMU 默认 `FS=zfs`。tmpfs 从 initramfs 复制初始文件，重启丢失修改；ZFS root 保留磁盘数据，并以只读内存节点暴露 initramfs 中缺失的顶层普通文件。磁盘同名文件优先，归档嵌套路径不通过此机制暴露。`/dev` 另行挂载 devfs。

普通构建不重建 `disk.img`；`make run/debug` 在 ZFS 模式缺少镜像时创建。以下显式磁盘操作会格式化目标镜像，替换其内容：

```sh
make disk
make disk ZFS_DISK_SIZE=20 COPY_TO_ZFS=false
zig build disk -Dzfs-disk-mb=20 -Dcopy-to-zfs=false
```

两种磁盘入口使用同一构建步骤，默认大小为 10 MiB，默认复制用户程序。ZFS v2 使用 12 个直接块和单级间接块，最大文件 4,243,456 字节，未启用双级、三级间接块。旧版本镜像不能视为 v2 兼容镜像。

QEMU 将 initramfs 单独加载到 `0x82300000`；DuoS 大核将其嵌入内核。ZFS 挂载失败后回退 tmpfs；块设备探测失败或缺少设备不属于该回退保证。

## 验证与文档

在 MMU 用户 shell 执行 `smpdemo` 可观察两个 worker 的 hart 采样；汇总 `0b11` 表示此次观察到两 hart，不是 CPU 亲和性保证。用户 `sleep` 的单位是 ticks，多 hart 共享计数不能直接当墙钟秒数。

```sh
python3 tools/run_syscheck.py
```

该工具使用临时磁盘进行 syscall 回归，不修改仓库 `disk.img`。通过标准及覆盖边界见 [syscheck](docs/SYSCHECK.md)。

- [文档导航与模块设计](obsidian/ZigguratOS-Knowledge-Base.md)
- [当前实现范围](docs/IMPLEMENTATION_STATUS.md)
- [VirtIO 存储设计](docs/VIRTIO_BLOCK_DRIVER.md)
- [REE 应用规划](roadmaps/ROADMAP_REE_Apps.md)
