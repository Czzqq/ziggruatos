# Rust 运行库支持与限制

## no_std 的责任分配

用户程序可使用 core 的基本类型、切片、迭代器与格式化；alloc 提供依赖堆的 Vec、String 等集合。ziggurat_core 提供分配器、入口、panic 和文件/控制台适配。当前没有完整 Rust std，也没有通用线程、网络或主机文件系统运行时。

## 固定堆设计

每个进程的库内静态区域提供 32768 字节堆，入口将其交给 buddy_system_allocator 的 LockedHeap。分配器可回收此区域内的内存，但不会向内核申请扩堆。sbrk 未接入内核分发，不能以存在其包装函数推断动态扩展可用。

参数转换本身会创建 Vec，因此启动参数也占用堆。大文件处理宜使用有限缓冲区循环读写，避免把整个文件一次装入 String。Vec/String 容量受固定堆与映射边界限制；这不是无限增长的标准桌面环境。

## I/O 与错误

文件操作封装描述符生命周期，格式化输出依靠 core::fmt::Write。File、Stdin、Stdout 是有限适配，没有完整 std::io::Read/Write 生态。读取返回 0 表示 EOF；一次短写应由调用者继续处理。格式化接口和原始字节接口的错误表示不同，不能默认获得细化 errno。

panic 处理打印位置和信息后请求 kill 当前 PID；分配错误进入 panic。它不提供栈展开或跨进程异常恢复。应用应尽量在可处理的边界检查输入和资源失败。

## 并发与依赖选择

fork 创建进程并复制地址空间；尚无用户线程 API 或协程运行时。LockedHeap 类型中的锁不代表内核已经提供用户线程支持。第三方 crate 应核对 no_std、目标架构和分配需求；依赖名称存在不能作为本项目已集成的证明。

调试使用 `make debug` 与另一终端的 `make gdb`。原生小核不加载这些应用，自己的内核任务共享 M-mode 内存。

实现依据：`src/user/lib/ziggurat_core/src/lib.rs`、`file.rs`、`Cargo.toml`。相关：[框架](1-User-Program-Framework.md)、[内存设计](../System-Design/3-Memory-Management-Design.md)。
