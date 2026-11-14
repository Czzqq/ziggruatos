# 内存管理设计

## 资源管理与映射分工

物理页管理器用位图管理板级指定的可分配区域；内核堆在其上提供满足 Zig allocator 接口的分配；页表模块负责地址翻译、权限和用户数据复制。将资源所有权与映射机制分离，使无 MMU 小核仍能复用物理页和堆。

引导分配器提供建立内存系统前的简单连续分配。运行阶段，物理页分配支持单页和连续页；小对象通过分配池降低按页分配浪费，大对象使用页资源。分配器必须处理对齐、耗尽和释放；分配器存在不代表可分配任意板外地址。

## 平台内存边界

| 平台 | 分配范围 | 初始文件来源 |
| --- | --- | --- |
| virt | `[0x80300000,0x82300000)` | `0x82300000` 外部 initramfs |
| duos | `[0x81000000,0x9fe00000)` | 内核只读数据中的 initramfs |
| duos-smallcore | `[0x9f800000,0xa0000000)` | 原生内核直接创建 tmpfs 内容 |

小核总所有权保留区为 `[0x9f000000,0xa0000000)`，前半区包含镜像、BSS、栈；Linux 必须排除整个保留区。这与大核独立启动配置是不同部署方案，不能同时混用内存分配假设。

## Sv39 地址空间

MMU 目标使用三级 Sv39 页表，页大小为 4 KiB。内核主体采用物理区域恒等映射，外设区域另行映射。每个用户进程有独立页表；页面权限区分读、写、执行和用户访问。

用户地址顶部保留 trampoline 与 trapframe。trampoline 在切换页表时提供稳定执行地址；trapframe 保存进程现场并受内核权限保护。任务内核栈另有映射和保护页。初始 initcode 映射在用户地址 0，不能声称所有进程始终有 NULL 保护页。

系统调用通过页表复制函数跨越用户边界，不能将用户虚拟地址直接当内核指针。fork 当前复制用户页，不使用写时复制。exec 重建用户映射。

## MMU 策略与同步

构建的 MMU 策略选择 Sv39 初始化或无地址翻译的物理内存路径。小核 getter 返回无页表，误用 Sv39 初始化/激活属于编译错误。关闭 MMU 不会生成用户态隔离。

物理分配、堆以及任务栈管理已有锁；本地页表切换使用 TLB fence。跨 hart shootdown 尚未形成完整机制，不能仅凭本地 fence 推断其他 hart 已看到映射变化。

用户 Rust 库另有固定 32 KiB 堆，不是内核堆的直接扩展；sbrk 未接入内核分发。

实现依据：`src/kernel/memory.zig`、`src/kernel/pagetable.zig`、`src/kernel/memory/sv39.zig`、`src/kernel/memory/nommu.zig` 与各 board config。相关：[启动](6-Boot-and-Initialization-Flow.md)、[Rust 运行库](../Userland-Implementation-Rust/3-Standard-Library-Support.md)。
