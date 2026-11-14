# 文档审查记录

审查日期：2026-11-14。审查对象是本地工作区源码和说明文档，结论来自静态核对，不代表 QEMU 或硬件运行验证。

## 协作方式

主 agent 负责决策和验收；审查 agent 只读核对并上报证据；文档 agent 按主 agent 指示修改文档，再交审查 agent 复核。行为规范见 [AGENTS.md](../AGENTS.md) 和 [角色说明](../agents/README.md)。

基线文档共 25 份：根 README（现已迁为 [README.md](../README.md)）、docs 下 5 份、obsidian 下 15 份、roadmaps 下 4 份。新增的协作规范和本记录也纳入交付检查。生成产物、二进制和外部固件不属于文档审查对象。

## 基线问题与纠正依据

| 问题 | 当前实现依据 | 修正方向 |
| --- | --- | --- |
| 构建说明仍要求 Kconfig 与手动生成 constants.zig | Makefile、build.zig 的 resolveOptions 与 generateAsmConstants | 使用当前 Zig 构建选项，移除失效步骤 |
| 文档建议 zig build run/debug/gdb | Makefile 的 run/debug/gdb 与 build.zig 的构建步骤 | 使用 Makefile 提供的交互工具入口 |
| zig build disk 被描述为空镜像、固定 10 MiB | build.zig 的 setupDiskSteps，大小与复制选项 | 说明显式格式化、可配置容量与复制行为 |
| ZFS 被描述为只支持 12 个直接块 | fs/zfs.zig 的 MAX_FILE_SIZE、getOrAllocDataBlock | 说明直接块与单级间接块的容量边界 |
| syscheck 示例仍为 7 项，用户态入口示例与实际不符 | syscheck/src/main.rs、ziggurat_core/src/lib.rs、用户链接脚本 | 对照实际 8 项测试、32 KiB 堆与入口契约改写 |
| 内核路径仍沿用重构前组织 | src/kernel/arch、fs、drivers、board 等模块 | 删除目录树和逐文件介绍，以职责和模块关系代替 |
| 双 hart 和 S-mode 被泛化到所有平台 | 各 board/config.zig、main_nommu.zig | 区分 virt、DuoS 大核与小核的运行契约 |
| 启动顺序与根文件系统失败语义过时 | main.zig、fs/bootstrap.zig | 说明先清 BSS；区分缺少块设备与挂载失败 |
| 大量代码摘录、目录树和重复能力列表 | obsidian 各设计文档、VirtIO 文档及路线图 | 以职责、设计取舍、交互边界和实现状态组织，保留必要操作命令 |

## 实现风险上报

静态检查发现 `src/kernel/block/block.zig` 的 `BlockDevice.sync` 使用 `self.lock.acquire;` 而非调用表达式，随后安排 `release()`。该实现需要独立修复和验证。本次文档任务未修改产品代码，不能据已有锁字段宣称同步或整个存储栈并发安全。

## 验收范围

已完成全部 25 份正文的改写或纠正，审查 agent 对规范及正文执行静态复审。主 agent 检查 28 份文档中的 82 个本地文件链接，无断链；`git diff --check` 通过。README 新增的页内导航不计入本地文件链接数量。

通过版本命令查询确认本地 Zig 为 `0.18.0-dev.35+5e754304d`，QEMU 为 `11.0.93 (v11.1.0-rc3)`。本轮未运行构建、QEMU 回归或硬件测试；历史输出和预期输出均不视为本次测试通过。
