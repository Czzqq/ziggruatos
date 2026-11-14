const std = @import("std");
const arch = @import("arch");
const io = arch.io;
const cfg = @import("board").config;

pub const hz: u64 = 1000;
const stack_size = 16384;
pub const Frame = extern struct { registers: [32]usize, pc: usize, status: usize };
pub const Task = struct {
    name: []const u8 = "",
    frame: *Frame = undefined,
    wake: u64 = 0,
    switches: u64 = 0,
    stack: [stack_size]u8 align(16) = undefined,
};
pub var tasks: [3]Task = @splat(.{});
pub var ticks: u64 = 0;
pub var on_tick: ?*const fn () void = null;
var current: usize = 0;
pub export var machine_fault_record: [4]usize = @splat(0);
extern fn native_resume(frame: *Frame) callconv(.c) noreturn;

comptime {
    if (arch.memory_policy.enabled) @compileError("native scheduler requires -Dmmu=off");
    if (@sizeOf(Frame) != 272) @compileError("machine trap frame layout mismatch");
}

pub fn clock() u64 {
    return arch.riscv.readTime();
}

fn armTimer() void {
    const deadline = clock() + cfg.timer.freq / hz;
    io.mmioWrite(u32, 0xffff_ffff, 0x7400_4004);
    io.mmioWrite(u32, @truncate(deadline), 0x7400_4000);
    io.mmioWrite(u32, @truncate(deadline >> 32), 0x7400_4004);
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

pub fn initTask(index: usize, name: []const u8, entry: *const fn () noreturn) void {
    const task = &tasks[index];
    task.name = name;
    const top = @intFromPtr(&task.stack) + stack_size;
    task.frame = @ptrFromInt(top - @sizeOf(Frame));
    task.frame.* = std.mem.zeroes(Frame);
    task.frame.registers[1] = @intFromPtr(&unexpectedReturn);
    task.frame.registers[2] = top;
    task.frame.pc = @intFromPtr(entry);
    task.frame.status = 0x1880;
}

pub fn start() noreturn {
    current = 0;
    tasks[0].switches = 1;
    armTimer();
    io.setCsr("mie", 0x80);
    native_resume(tasks[0].frame);
}

pub fn sleep(duration: u64) void {
    const enabled = arch.riscv.archLocalIrqState();
    arch.riscv.archLocalIrqDisable();
    tasks[current].wake = ticks + @max(duration, 1);
    asm volatile ("ecall" ::: .{ .memory = true });
    if (enabled) arch.riscv.archLocalIrqEnable();
}

fn unexpectedReturn() noreturn {
    @panic("kernel task returned");
}

pub export fn native_dispatch(frame: *Frame) callconv(.c) *Frame {
    const cause = io.readCsr("mcause");
    if (cause == 0x8000_0000_0000_0007) {
        ticks +%= 1;
        armTimer();
        if (on_tick) |poll| poll();
    } else if (cause == 11) {
        frame.pc += 4;
    } else {
        machine_fault_record = .{ cause, frame.pc, io.readCsr("mtval"), frame.status };
        io.writeCsr("mie", 0);
        while (true) asm volatile ("wfi");
    }
    tasks[current].frame = frame;
    var offset: usize = 1;
    while (offset <= tasks.len) : (offset += 1) {
        const candidate = (current + offset) % tasks.len;
        if (tasks[candidate].wake <= ticks) {
            current = candidate;
            tasks[current].switches +%= 1;
            return tasks[current].frame;
        }
    }
    @panic("no runnable native task");
}
