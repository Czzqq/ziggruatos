# 设备与驱动设计

## 分层职责

| 层 | 责任 | 协作方式 |
| --- | --- | --- |
| board / platform | 硬件参数、探测及平台初始化 | 选择 UART，向上交付块设备 |
| drivers | UART、PLIC、VirtIO 等协议 | 接收初始化所需服务，避免导入内核造成依赖环 |
| device | 设备号、名称及字符/块操作表 | 注册和查询设备，不解析文件路径 |
| block | 固定大小块读写、缓存和串行化 | 包装已注册块设备 |
| devfs / VFS | 设备路径与打开文件操作 | 将 `/dev` 访问转到设备操作 |

设备对象持有驱动上下文，操作表避免上层绑定具体硬件类型。字符设备按字节读写；块设备公开块大小、容量和按块操作。向注册表登记设备不会自动赋予所有路径或 syscall 能力。

## 平台选择

QEMU virt 使用 NS16550 UART、PLIC 和 VirtIO MMIO；DuoS 使用 DW APB UART 与芯片地址配置。控制台通过注册 serial 设备与 devfs 暴露文件接口。设备注册在根 VFS 及 devfs 挂载流程中衔接。

MMU 平台启动根 ZFS 时调用平台块设备探测，将所得 BlockDevice 注入文件系统 bootstrap。文件系统不负责扫描 QEMU MMIO，也不应反向依赖内核入口。

## 块路径与并发

VirtIO 驱动负责设备握手、队列和数据传输。block 层提供可选的读缓存、写穿更新，并在每个句柄的读写周围加锁。默认缓存采用轮转替换，不是 LRU，也没有写回策略。

VirtIO 当前复用单一全局请求缓冲区并同步轮询。通过同一句柄的块锁可串行化访问，但多个句柄或直接调用驱动不能据此认为安全。VFS/ZFS 的多步修改还需更高层同步。

## 小核所有权

原生小核仅使用独占 UART1、本地定时器和保留 DDR；Linux 保留其他硬件。小核不探测块存储，不操作共享 PLIC，使用 tmpfs/devfs。板级启动必须兑现内存和外设排他所有权，软件分层本身不能代替该契约。

实现依据：`src/kernel/device/device.zig`、`src/kernel/drivers/`、`src/kernel/block/block.zig`、`src/kernel/fs/devfs.zig`。详见 [VirtIO 块设备](../../docs/VIRTIO_BLOCK_DRIVER.md)。
