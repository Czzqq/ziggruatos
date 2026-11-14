const builtin = @import("std").builtin;

const StackTrace = builtin.StackTrace;

const std = @import("std");

const common = @import("common");
const utils = common.utils;

const arch = @import("arch");
const io = arch.io;
const sbi = arch.sbi;
const riscv = arch.riscv;
const cpu = arch.cpu;

const drivers = @import("drivers");
const plic = drivers.plic;
const block = @import("block");

const board_cfg = @import("board").config;

const console = @import("console.zig");
const device = @import("device");
const fs = @import("fs");
const devfs = fs.devfs;
const fs_bootstrap = fs.bootstrap;
const memory = @import("memory.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
const task = @import("task.zig");
const vfs = @import("fs").vfs;

const platform = @import("platform");

const Serial = console.Serial;

const kprint = utils.kprint;

extern fn _start_secondary() callconv(.naked) void;

fn earlyDebug(comptime message: []const u8) void {
    if (comptime board_cfg.boot_trace and board_cfg.uart0.kind == .dw_apb) {
        for (message) |c| {
            if (c == '\n') sbi.putChar('\r');
            sbi.putChar(c);
        }
    }
}

fn faultDebug(comptime message: []const u8) void {
    if (comptime board_cfg.uart0.kind == .dw_apb) {
        for (message) |c| {
            if (c == '\n') drivers.uart.put('\r');
            drivers.uart.put(c);
        }
    }
}

fn clearBss() void {
    const bss_start = @as([*]u8, @ptrCast(&utils.sbss));
    const _bss_size = @intFromPtr(&utils.ebss) - @intFromPtr(&utils.sbss);

    for (0.._bss_size) |i| {
        bss_start[i] = 0;
    }
}

pub fn panic(msg: []const u8, stack_trace: ?*StackTrace, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = stack_trace;
    _ = first_trace_addr;
    Serial.write("KERNEL PANIC: ");
    Serial.write(msg);
    Serial.write("\n");
    while (true) {}
}

pub export fn do_exception(regs: *trap.trapFrame, scause: usize) callconv(.c) void {
    _ = trap.kTrapExceptionHandler(regs, scause);
}

pub export fn kmain() noreturn {
    earlyDebug("SBI: before clearBss\n");
    clearBss();
    earlyDebug("SBI: after clearBss\n");
    // Early print
    earlyDebug("SBI: before UART init\n");
    Serial.uartInit();
    earlyDebug("SBI: after UART init\n");
    Serial.write("\n");
    Serial.write("==========================================================\n");
    Serial.write("| Hello, Kernel World from Zig 0.18 dev(35+5e754304d)! |\n");
    Serial.write("==========================================================\n");
    Serial.write("\n");
    earlyDebug("SBI: after banner\n");
    earlyDebug("SBI: before console init\n");
    console.init();
    earlyDebug("SBI: after console init\n");

    earlyDebug("SBI: before displayMem\n");
    utils.displayMem();
    earlyDebug("SBI: after displayMem\n");

    if (comptime board_cfg.uart0.kind == .dw_apb) {
        const watchdog_base: usize = 0x0301_0000;
        const watchdog_cr = io.mmioRead(u32, watchdog_base);
        const watchdog_torr = io.mmioRead(u32, watchdog_base + 4);
        kprint("WDT: CR=0x{x}, TORR=0x{x}\n", .{ watchdog_cr, watchdog_torr });
    }

    trap.trapInit();
    timer.timerInit();
    _ = plic.plicInit();
    Serial.enableUartPlic();
    memory.memInit();

    device.init();
    device.register(&console.serial_device) catch @panic("register serial device failed");

    // Initialize filesystem based on compile-time configuration
    const blk: ?*block.BlockDevice = if (fs.Config.use_zfs_root)
        platform.probeBlock(memory.kernelAllocator()) catch {
            @panic("probe block failed\n");
        }
    else
        null;

    const fs_info = fs_bootstrap.initFilesystem(memory.kernelAllocator(), blk) catch |err| {
        kprint("Filesystem initialization failed: {}\n", .{err});
        @panic("filesystem initialization failed");
    };

    // Initialize VFS
    kprint("Initializing VFS with root filesystem...\n", .{});
    vfs.init_vfs(memory.kernelAllocator(), fs_info.root_fs) catch unreachable;
    kprint("VFS initialized successfully\n", .{});

    // Populate filesystem
    fs_bootstrap.populateRoot(fs_info);

    fs_bootstrap.ensureDevMountpoint() catch @panic("create /dev failed");
    const devfs_fs = devfs.mount(memory.kernelAllocator()) catch @panic("devfs mount failed");
    vfs.get_vfs().mount("/dev", devfs_fs) catch @panic("mount /dev failed");

    kprint("System initialization complete\n", .{});

    earlyDebug("SBI: before userinit\n");
    task.proc.userinit();
    earlyDebug("SBI: after userinit\n");
    // Publish the initial task and bootstrap CPU before other harts can schedule.
    bootSecondaryHarts();
    earlyDebug("SBI: before scheduler\n");
    task.proc.scheduler();

    while (true) {}
}

fn bootSecondaryHarts() void {
    const start_addr = @intFromPtr(&_start_secondary);

    for (1..board_cfg.max_cpus) |hartid| {
        kprint("Starting hart {}...\n", .{hartid});
        const ret = sbi.hart_start(hartid, start_addr, 0);
        if (ret != 0) {
            kprint("Failed to start hart {} start_addr 0x{x}: error {x}\n", .{ hartid, start_addr, ret });
        }
    }
}

pub export fn kmain_secondary() noreturn {
    const hartid: u32 = @intCast(riscv.riscvReadTp());

    // Activate kernel page table on this hart
    const kpgtbl = memory.getKernelPageTable() orelse {
        @panic("secondary: no kernel page table");
    };
    memory.sfenceVma();
    io.writeCsr("satp", riscv.SATP_SV39 | (@intFromPtr(kpgtbl.root) >> 12));
    memory.sfenceVma();

    // Per-hart trap vector
    trap.trapInit();

    // Per-hart timer
    timer.timerInit();

    // Register this CPU before enabling interrupts in the scheduler.
    _ = cpu.PerCpu.alloc(hartid) catch {
        @panic("secondary: percpu alloc failed");
    };

    kprint("Hart {} online, entering scheduler\n", .{hartid});

    // Enter scheduler loop (shared task_list, will need locking later)
    task.proc.scheduler();

    while (true) {}
}
