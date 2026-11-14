# VirtIO 块设备设计

## 责任与调用链

QEMU virt 平台探测 VirtIO MMIO 块设备，将设备注册并包装为 BlockDevice，再交给根文件系统启动策略。VirtIO 层负责 MMIO 协议和队列；块层负责逻辑块接口与缓存；ZFS 负责磁盘格式。文件系统不直接扫描 MMIO。

实现依据是 `src/kernel/drivers/virtio.zig`、`virtio_blk.zig`、`src/kernel/block/block.zig` 和 `src/kernel/board/virt/init.zig`。当前驱动只有一个全局设备实例，不是通用多设备队列框架。

## 队列与初始化契约

驱动依次重置设备、确认驱动身份、协商特性、配置 queue 0 并设置 DRIVER_OK。初始化会核对队列容量和设备对特性的接受情况。队列大小为 16，但当前请求链复用描述符 0..2，不能据此推断同时支持 16 个并发请求。

| 区域 | 所有权与作用 |
| --- | --- |
| descriptor table | 驱动描述请求头、数据和状态三段缓冲区 |
| available ring | 驱动发布链头，设备读取 |
| used ring | 设备发布完成，驱动轮询 |

Legacy 版本通过页大小和 PFN 配置连续队列内存，used ring 需要相应页对齐；modern 分支分别配置三个区域的 64 位地址并置 QueueReady。存在分支不代表本次已验证全部设备版本。内存地址转换依赖当前内核映射约定，不是通用 IOMMU 支持。

## 请求与单位

驱动预分配请求头、状态字节和 4096 字节数据缓冲区。读写构造三段描述符链，数据方向决定设备可写标志，状态段由设备写回。发布 available index 之前和通知设备之前需要 fence，完成读取也要遵守设备可见性顺序。

VirtIO 请求头使用 512 字节 sector 单位；向 block 层暴露的逻辑块大小为 4096 字节，适配层负责单位转换。混淆这两个单位会定位到错误磁盘位置。

提交过程通知 queue 0 后同步轮询 used ring，并有循环次数超时。超时不是精确墙钟期限；即使初始化使能了 PLIC IRQ，当前请求完成仍通过轮询判断，不是睡眠等待中断的异步模型。

## 缓存与并发边界

BlockDevice 默认使用 8 项轮转替换缓存，读命中直接复制，写操作先写底层再更新缓存；没有写回脏块策略。read/write 在同一打开句柄上持锁，使其缓存和底层调用串行化。

驱动本身复用全局缓冲区，多句柄或绕过 block 层直接调用仍需额外约束。ZFS/VFS 多步骤修改不由块锁提供原子性。flush/sync 路径和掉电恢复不能因读写成功而视为已验证。

## 运行与诊断

```sh
make run FS=zfs
python3 tools/run_syscheck.py
```

启动时观察设备识别、队列和根挂载结果；无块设备、特性拒绝、队列不足和请求超时应分别定位。请求超时可检查地址、描述符方向、ring 初始化/对齐及 fence；文件读错还要检查 sector 与逻辑块换算、镜像格式版本。

syscheck 使用临时 ZFS 镜像验证基础文件系统 syscall 行为，不能代替多 hart 存储并发、设备故障或掉电一致性测试。普通 `make run` 重用 `disk.img`；只有明确需要重建内容时才执行格式化命令，详见 [README](../README.md)。

DuoS 大核默认 tmpfs；小核由 Linux 持有存储，不使用此驱动。
