# SG2000 / Milk-V Duo S native small-core target

C906L has **no MMU**. RT-Thread's official `bsp/cvitek/README.md` explicitly
distinguishes c906-little from MMU-equipped c906-big and excludes RT-Smart for
the little core. This target is a native M-mode ZigguratOS backend. The large core continues to run SDK Linux.

## Compile-time MMU policy

```sh
zig build kernel -Dplatform=virt -Dmmu=on
zig build kernel -Dplatform=duos -Dfs=tmpfs -Dmmu=on
zig build kernel -Dplatform=duos-smallcore -Dmmu=off -Doptimize=ReleaseSmall
make duos-smallcore
```

`virt` and `duos` default to `on` and retain their existing Sv39 page tables,
S-mode scheduler, process isolation, Rust applications and packaging. The
small-core target defaults to `off`. Explicit `on` for C906L is rejected at
build time. Explicit `off` on existing large-core/QEMU boards is also rejected:
they do not yet have a validated native M-mode board backend. This does not
claim that toggling a flag gives those boards a working alternative platform.

`arch.memory_policy.enabled` is the shared compile-time API. Physical-page and
kernel-heap allocators are shared. `memory/sv39.zig` initializes the existing
page tables and activates paging; `memory/nommu.zig` only selects physical
allocation, with no translation setup or fencing. The existing pagetable
implementation is retained. Accidental calls to Sv39 initialization/activation
under `-Dmmu=off` are compile errors; the page-table getter returns null.
Interrupt-mask helpers select S-status for MMU boards and M-status for native
execution. Native assembly contains no S-mode CSRs, satp, sfence or SBI calls.

## Native functionality and limits

The native target has full integer-register M-mode trap save/restore, a 1 kHz
local CLINT timer, three separate 16 KiB task stacks and round-robin preemption:
an interactive UART shell, an intentionally non-yielding worker and an idle
task. `sleep` blocks one task until timer ticks expire. A 256-byte RX ring is
filled each timer tick, without PLIC setup or UART interrupts. Shared OS
physical-page/kernel-heap allocators back the existing VFS, tmpfs and devfs;
`/dev/serial` and `/hello` are created at boot.

Shell commands: `help`, `uptime`, `tasks`, `mem`, `ls [path]`, `cat path`,
`write path text`, `touch path`, `mkdir path`, `rm path`, `sleep milliseconds`,
`selftest`. The self-test checks timer and non-yielding worker progress, real
allocator allocate/free and VFS/tmpfs write/read/delete. tmpfs is RAM-only.
It also checks 8, 16 and 4096-byte allocation alignment, allocation failure
at the reservation limit, and reuse after freeing a multi-page allocation.
Overlong shell input is discarded through newline, without executing its prefix.

No MMU means no process address-space isolation. All native tasks are trusted
and execute in one M-mode address space; PMP does not isolate those M-mode
tasks. Existing zero-linked Rust user ELFs, U-mode fork/exec/syscalls and the
old MMU userspace shell are **not supported**. A noMMU load/relocation ABI is
future work. The native build deliberately does not build/embed those ELFs or
an initramfs. The deployment contract is independent of the large-core FIP flow.

## Firmware and ownership contract

Use Zig `0.18.0-dev.35+5e754304d` and Python 3. Native builds do not require Rust,
cpio or a strip tool. Outputs are `zig-out/bin/zigguratOS-duos-smallcore` (ELF),
the corresponding `.bin` raw firmware and adjacent `.bin.json` metadata.

- BLCP_2ND raw load/reset entry: `0x9f000000`.
- Owned DDR: `[0x9f000000,0xa0000000)`, 16 MiB, excluded from Linux.
- First 8 MiB: image, BSS and all stacks, bounded by linker/ELF checks.
- Shared heap/page allocator: `[0x9f800000,0xa0000000)`, 8 MiB.
- Metadata schema 1, target `sg2000-c906l`, raw format, full `memory_size`
  16777216, `uart_index` 1 and SHA-256 of the raw file.
- Local hart ID 0, as in SDK FreeRTOS. Local compare `0x74004000`; `rdtime`
  frequency 25 MHz. Unexpected harts park without peripheral writes.
- Exclusive UART1 `0x04150000`, 25 MHz, 115200 8N1, 32-bit shifted registers.
  UART0 remains Linux's console. Before UART access, native startup performs
  masked 32-bit RMW on the exclusively owned A19/A18 funcsel registers
  `0x03001064`/`0x03001068`, setting only bits 2:0 to selector 6, followed by
  `fence iorw,iorw`. U-Boot/Linux must preserve ownership and clocking. No other
  pinmux, clock, reset or pad-control registers are written. CLINT compare is
  programmed as high=all-ones, low=deadline-low, high=deadline-high using only
  32-bit MMIO followed by an I/O fence, matching the SDK's split registers.

Startup uses SDK-proven local cache CSRs, invalidates local caches, enables
I-cache and leaves D-cache off. It clears BSS but not the active boot stack.
Machine faults retain cause/PC/mtval/status at `machine_fault_record` and park.
No shared PLIC claim/priority/enable writes, Linux DDR allocation, mailbox,
watchdog, GPIO, camera, network or storage access is performed. FreeRTOS vendor
multimedia/mailbox services are unsupported and must stay disabled in Linux.
Use SDK opt-in firmware import, not the old large-core `duos-fip` command.

## Validation gates

Check the ELF/raw metadata and complete 1 MiB FIP storage limit separately;
the larger RAM reservation does not enlarge FIP storage. Inspect disassembly
to ensure the native image has no satp/sfence/S-mode CSR instructions, and
test invalid MMU/platform combinations. Build/regression-check existing
MMU targets without modifying their address maps or userland semantics.
Host compilation is not proof of physical boot. Board validation still needs
both Linux and native shell simultaneously, `selftest`, advancing worker/task
counters, UART input under timer preemption, allocator/file operations and
Linux's correct memory/device exclusion. Never describe the native port as
supporting the original MMU userspace processes or as memory-isolated.
