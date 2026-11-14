# 启动与初始化流程

## 镜像与板级选择

MMU 目标由 SBI 固件移交 S-mode。QEMU virt 使用外部 initramfs，DuoS 大核使用线性镜像与嵌入式 initramfs。链接布局和启动汇编必须匹配对应 board，不能交换镜像部署方式。

QEMU 将内核加载到 `0x80200000`，归档加载到 `0x82300000`；可分配区域为两者之间的板级指定范围。普通代码的加载/运行位置由链接脚本与启动复制配合。启动栈位于 BSS 清零范围之外，以免清零当前栈。CPU 数与汇编常量由 build.zig 自动生成。

## 主 hart 的职责

当前启动假定主 hart 为 0，不动态枚举所有 CPU。

1. 汇编准备启动栈、hart 身份及镜像运行条件，进入 kmain。
2. 清零 BSS，然后初始化 UART 和控制台，输出启动信息。
3. 初始化陷阱、定时器、PLIC、UART 中断及内存系统。
4. 初始化设备注册表，登记 serial；需要 ZFS 时通过 platform 探测块设备。
5. 文件系统 bootstrap 选择根后端，VFS 接管根路径，填充初始文件，再挂载 devfs 到 `/dev`。
6. 创建初始用户任务与主 hart 的 PerCpu，发布共享任务状态。
7. 按 board CPU 数通过 SBI HSM 启动从 hart，进入调度器。

共享内存、根文件系统与初始任务在从 hart 启动之前建立，避免重复初始化或调度未完成的对象。

## 从 hart 的职责

从 hart 使用 SBI 参数中的 hart ID 选择自己的启动栈，激活已建立的内核页表，初始化本地陷阱、定时器与 PerCpu，再进入共享任务列表调度。它不会清 BSS、重建根文件系统或重新注册控制台。

QEMU 配置两 hart；DuoS 大核配置一 hart。`make run/debug` 都按 QEMU virt 使用两个 hart，所选固件需要支持 HSM。启动调用失败应结合固件和目标平台判断。

## 根目录与首个程序

显式 tmpfs 将 initramfs 复制到 RAM。ZFS 挂载成功后暴露归档中磁盘缺失的顶层普通文件，磁盘同名文件优先。ZFS 挂载失败设置 tmpfs 状态，转入复制路径；设备探测失败或没有块设备会报错，不保证回退。

首个用户任务不直接加载 ELF，而先运行一页内嵌 initcode，映射在用户地址 0，再 exec `/init`。用户 init 启动 shell。进程页表顶部的 trampoline/trapframe 支持返回用户态，主体内核为恒等映射。

## 原生小核路径

C906L 使用独立 M-mode 入口。它初始化独占 UART1、物理分配、tmpfs/devfs 和固定内核任务，再由本地 CLINT 定时器抢占调度。这里没有 SBI、Sv39、initramfs 或 U-mode ELF 装载；完整所有权契约见 [小核部署](../../docs/DUOS_SMALLCORE.md)。

## 观察与验证

MMU 启动以进入用户 shell 为基本观察点。QEMU 可继续执行 smpdemo 和 syscheck，检查实际 hart 采样与 syscall 行为。日志显示某一初始化阶段完成只证明到达该阶段，不能代替后续硬件交互或并发验证。

实现依据：`src/kernel/main.zig`、`src/kernel/main_nommu.zig`、`src/kernel/arch/asm/boot.S`、`src/kernel/fs/bootstrap.zig`、`src/kernel/task.zig` 与 board 配置。
