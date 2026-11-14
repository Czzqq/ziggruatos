# RISC-V 底层支持

## 架构层职责

arch 模块集中提供 CSR、MMIO、SBI、自旋锁和 PerCpu 操作。其他构建模块通过公开导出使用这些机制；板级地址、时钟、UART 类型和 CPU 数由 board 描述，避免把 QEMU 地址写成所有平台的共同事实。

MMU 目标由 M-mode 固件进入 S-mode 内核，U-mode 运行用户程序。SBI 提供定时器和 hart 启动等机器级服务。QEMU virt 配置两个 hart，DuoS 大核配置一个；SBI HSM 可用性由实际固件决定。

## 执行现场与 CPU 身份

内核使用 tp 保存当前 hart ID，索引 PerCpu。用户寄存器由 trapframe 保存，进入内核时恢复内核 hart 身份。不能把任意用户 tp 当作内核 CPU 索引。

中断屏蔽是临界区和锁协议的一部分。S-mode 使用 supervisor 状态寄存器，小核 M-mode 使用 machine 状态寄存器。屏蔽本 hart 中断不能替代多 hart 共享数据锁。

## 地址翻译与构建契约

MMU 路径使用 satp 选择 Sv39 页表，本地 fence 使地址翻译切换生效。页表权限和物理资源分配由上层内存模块负责。汇编使用的 CPU 数、栈和 trampoline 常量由 build.zig 自动生成；无需手动 translate-c 生成旧文件。

小核 C906L 没有 MMU，原生启动、陷阱和定时器使用 M-mode 机制，禁止 Sv39 初始化路径。它不通过 SBI 获得服务，也不继承 S-mode 用户进程模型。

## 调试边界

出现启动错误应先确认目标 board、固件模式、镜像加载位置与串口选择。trap 错误还需结合 cause、PC 和故障地址判断；CSR 数值本身不能证明根因。芯片特有缓存与页表属性由相应板级契约约束。

实现依据：`src/kernel/arch/`、`src/kernel/board/`、`build.zig`。相关：[内存](../System-Design/3-Memory-Management-Design.md)、[启动](../System-Design/6-Boot-and-Initialization-Flow.md)、[DuoS 小核](../../docs/DUOS_SMALLCORE.md)。
