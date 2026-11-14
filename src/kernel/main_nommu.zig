const std = @import("std");
const arch = @import("arch");
const memory = @import("memory.zig");
const fs = @import("fs");
const device = @import("device");
const uart = @import("drivers").uart;
const utils = @import("common").utils;
const scheduler = @import("board/duos-smallcore/scheduler.zig");
const cfg = @import("board").config;

var receive: [256]u8 = undefined;
var read_index: usize = 0;
var write_index: usize = 0;
var dropped: u64 = 0;
var worker_count: u64 = 0;
var line_start = true;
var output_irq = false;
var root_fs: *fs.vfs.FileSystem = undefined;

comptime {
    if (arch.memory_policy.enabled) @compileError("C906L native kernel must not enable MMU");
}

fn output(data: []const u8) void {
    for (data) |character| {
        if (character == '\n') uart.put('\r');
        uart.put(character);
        line_start = character == '\n';
    }
}

fn atLineStart() bool { return line_start; }
fn cpuId() usize { return 0; }
fn lockOutput() void {
    output_irq = arch.riscv.archLocalIrqState();
    arch.riscv.archLocalIrqDisable();
}
fn unlockOutput() void {
    if (output_irq) arch.riscv.archLocalIrqEnable();
}
fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "output too long\n";
    output(text);
}

fn pollInput() void {
    while (uart.get()) |character| {
        const next = (write_index + 1) % receive.len;
        if (next == read_index) {
            dropped +%= 1;
        } else {
            receive[write_index] = character;
            write_index = next;
        }
    }
}

fn getInput() ?u8 {
    const enabled = arch.riscv.archLocalIrqState();
    arch.riscv.archLocalIrqDisable();
    defer if (enabled) arch.riscv.archLocalIrqEnable();
    if (read_index == write_index) return null;
    const character = receive[read_index];
    read_index = (read_index + 1) % receive.len;
    return character;
}

fn serialRead(_: *anyopaque, buffer: []u8, _: usize) anyerror!usize {
    if (buffer.len == 0) return 0;
    while (true) {
        if (getInput()) |character| {
            buffer[0] = character;
            return 1;
        }
        scheduler.sleep(1);
    }
}
fn serialWrite(_: *anyopaque, buffer: []const u8, _: usize) anyerror!usize {
    output(buffer);
    return buffer.len;
}
var serial_context: u8 = 0;
const serial = device.Device{
    .num = .{ .major = 1, .minor = 0 },
    .dev_type = .Char,
    .name = "serial",
    .ctx = &serial_context,
    .ops = .{ .Char = .{ .read = &serialRead, .write = &serialWrite } },
};

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    arch.riscv.archLocalIrqDisable();
    arch.io.writeCsr("mie", 0);
    output("KERNEL PANIC: ");
    output(message);
    output("\n");
    while (true) asm volatile ("wfi");
}

pub export fn native_main() noreturn {
    uart.init();
    utils.installConsole(.{ .write = &output, .now = &scheduler.clock, .cpuId = &cpuId, .atLineStart = &atLineStart, .lockOutput = &lockOutput, .unlockOutput = &unlockOutput });
    output("\nZigguratOS SG2000 C906L: native M-mode, MMU=off, hart 0\n");
    output("Kernel tasks share memory; legacy MMU user ELFs/syscalls are unsupported.\n");
    _ = arch.cpu.PerCpu.alloc(0) catch @panic("CPU initialization failed");
    memory.memInit();
    const allocator = memory.kernelAllocator();
    root_fs = fs.tmpfs.init_tmpfs(allocator, 4 * 1024 * 1024) catch @panic("tmpfs initialization failed");
    fs.vfs.init_vfs(allocator, root_fs) catch @panic("VFS initialization failed");
    device.init();
    device.register(&serial) catch @panic("serial registration failed");
    fs.vfs.get_vfs().mkdir("/dev") catch @panic("create /dev failed");
    const dev = fs.devfs.mount(allocator) catch @panic("devfs initialization failed");
    fs.vfs.get_vfs().mount("/dev", dev) catch @panic("mount /dev failed");
    writeFile("/hello", "ZigguratOS native M-mode tmpfs\n") catch @panic("tmpfs bootstrap failed");
    scheduler.on_tick = &pollInput;
    scheduler.initTask(0, "shell", &shellTask);
    scheduler.initTask(1, "worker", &workerTask);
    scheduler.initTask(2, "idle", &idleTask);
    scheduler.start();
}

fn workerTask() noreturn {
    while (true) _ = @atomicRmw(u64, &worker_count, .Add, 1, .monotonic);
}
fn idleTask() noreturn {
    while (true) asm volatile ("wfi");
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const file = try fs.vfs.get_vfs().open(path, .{ .write = true, .create = true }, null);
    defer memory.kernelAllocator().destroy(file);
    if (try file.write(contents) != contents.len) return error.ShortWrite;
}

fn command(line: []const u8) !void {
    var arguments = std.mem.tokenizeAny(u8, line, " \t");
    const name = arguments.next() orelse return;
    const vfs = fs.vfs.get_vfs();
    if (std.mem.eql(u8, name, "help")) {
        output("help uptime tasks mem ls [path] cat path write path text touch path mkdir path rm path sleep ms selftest\n");
    } else if (std.mem.eql(u8, name, "uptime")) {
        print("ticks={d} time_ms={d} rx_dropped={d}\n", .{ scheduler.ticks, scheduler.clock() / (cfg.timer.freq / 1000), dropped });
    } else if (std.mem.eql(u8, name, "tasks")) {
        for (&scheduler.tasks) |*task| print("{s} switches={d} wake={d}\n", .{ task.name, task.switches, task.wake });
        print("non-yielding worker iterations={d}\n", .{@atomicLoad(u64, &worker_count, .monotonic)});
    } else if (std.mem.eql(u8, name, "mem")) {
        const system = try memory.MemorySystem.get();
        print("owned=[0x9f000000,0xa0000000) allocator free={d}/{d} pages\n", .{ system.pmm.free_pages, system.pmm.total_pages });
    } else if (std.mem.eql(u8, name, "ls")) {
        const entries = try vfs.readdir(arguments.next() orelse "/");
        defer memory.kernelAllocator().free(entries);
        for (entries) |entry| print("{s}\n", .{entry.name});
    } else if (std.mem.eql(u8, name, "cat")) {
        const file = try vfs.open(arguments.next() orelse return error.MissingPath, .{ .read = true }, null);
        defer memory.kernelAllocator().destroy(file);
        var buffer: [128]u8 = undefined;
        while (true) {
            const count = try file.read(&buffer);
            if (count == 0) break;
            output(buffer[0..count]);
            file.offset += count;
        }
        output("\n");
    } else if (std.mem.eql(u8, name, "write")) {
        const path = arguments.next() orelse return error.MissingPath;
        try writeFile(path, arguments.rest());
    } else if (std.mem.eql(u8, name, "touch")) {
        try writeFile(arguments.next() orelse return error.MissingPath, "");
    } else if (std.mem.eql(u8, name, "mkdir")) {
        try vfs.mkdir(arguments.next() orelse return error.MissingPath);
    } else if (std.mem.eql(u8, name, "rm")) {
        try vfs.remove(arguments.next() orelse return error.MissingPath);
    } else if (std.mem.eql(u8, name, "sleep")) {
        const duration = try std.fmt.parseUnsigned(u32, arguments.next() orelse return error.MissingDuration, 10);
        scheduler.sleep(duration);
    } else if (std.mem.eql(u8, name, "selftest")) {
        const before = scheduler.ticks;
        const progress = @atomicLoad(u64, &worker_count, .monotonic);
        scheduler.sleep(10);
        if (scheduler.ticks <= before or @atomicLoad(u64, &worker_count, .monotonic) <= progress) return error.TimerOrPreemptionFailed;
        const allocator = memory.kernelAllocator();
        inline for (.{ 8, 16, 4096 }) |alignment| {
            const aligned = try allocator.alignedAlloc(u8, .fromByteUnits(alignment), 96);
            if (@intFromPtr(aligned.ptr) % alignment != 0) return error.MemoryAlignmentFailed;
            @memset(aligned, 0x5a);
            allocator.free(aligned);
        }
        const system = try memory.MemorySystem.get();
        const free_before = system.pmm.free_pages;
        if (allocator.alloc(u8, cfg.kernel_memory.size)) |unexpected| {
            allocator.free(unexpected);
            return error.ExhaustionFailed;
        } else |failure| {
            if (failure != error.OutOfMemory) return failure;
        }
        const probe = try allocator.alloc(u8, 8192);
        @memset(probe, 0x5a);
        allocator.free(probe);
        if (system.pmm.free_pages != free_before) return error.MemoryReuseFailed;
        try writeFile("/selftest", "nommu-vfs-pass");
        const file = try vfs.open("/selftest", .{ .read = true }, null);
        defer allocator.destroy(file);
        var buffer: [32]u8 = undefined;
        const count = try file.read(&buffer);
        if (!std.mem.eql(u8, buffer[0..count], "nommu-vfs-pass")) return error.FilesystemFailed;
        try vfs.remove("/selftest");
        output("PASS timer preemption worker alignment exhaustion allocator VFS/tmpfs\n");
    } else {
        output("unknown command; type help\n");
    }
}

fn shellTask() noreturn {
    var line: [192]u8 = undefined;
    var used: usize = 0;
    var overflowed = false;
    var last_cr = false;
    output("ziggurat-m> ");
    while (true) {
        if (getInput()) |character| {
            if (character == '\n' and last_cr) { last_cr = false; continue; }
            last_cr = character == '\r';
            if (character == '\r' or character == '\n') {
                output("\n");
                if (overflowed) {
                    output("error: command too long\n");
                } else {
                    command(line[0..used]) catch |failure| print("error: {s}\n", .{@errorName(failure)});
                }
                used = 0;
                overflowed = false;
                output("ziggurat-m> ");
            } else if (!overflowed and (character == 8 or character == 127) and used != 0) {
                used -= 1;
                output("\x08 \x08");
            } else if (character >= 32 and character < 127 and !overflowed) {
                if (used == line.len) {
                    overflowed = true;
                } else {
                    line[used] = character;
                    used += 1;
                    uart.put(character);
                }
            }
        } else scheduler.sleep(1);
    }
}
