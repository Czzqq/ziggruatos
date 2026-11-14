const std = @import("std");
const builtin = @import("builtin");

const arch = @import("arch");
const io = arch.io;
const sbi = arch.sbi;

const utils = @import("common").utils;
const board_cfg = @import("board").config;

const SpinLock = @import("arch").spinlock.SpinLock;

const CACHE_LINE_SIZE = 64;

const SIE_STIE: usize = 0x20;
// Verbose trap tracing over a slow UART can take longer than a 1 ms tick.
// Keep traced diagnostic builds schedulable; production builds retain 1 kHz.
const HZ: usize = if (board_cfg.boot_trace) 10 else 1000;

const AtomicJiffies = struct {
    value: std.atomic.Value(u64) align(CACHE_LINE_SIZE),

    pub fn init() @This() {
        return @This(){
            .value = std.atomic.Value(u64).init(0),
        };
    }

    pub fn get(self: *const @This()) u64 {
        return self.value.load(.monotonic);
    }

    pub fn set(self: *@This(), val: u64) void {
        self.value.store(val, .monotonic);
    }

    pub fn increment(self: *@This()) u64 {
        return self.value.fetchAdd(1, .monotonic);
    }
};

pub var jiffies = AtomicJiffies.init();
pub var ticks_lock: SpinLock = SpinLock.init("ticks");

// there are many ways to get timer val
//      1. mmio read 0x200bff8, but the Reg belong to M-Mode
//              const cycles_mmio = io.mmioRead(u64, VIRT_CLINT_TIMER_VAL);
//      2. with 'rdtime' asm volatile code
//              const cycles_rdtime = asm volatile ("rdtime %[cycles]" : [cycles] "=r" (-> u64));
//      3. read ‘time’ csr
//              const cycles_csr = io.readCsr("time");
inline fn getCycles() u64 {
    return asm volatile ("rdtime %[cycles]"
        : [cycles] "=r" (-> u64),
    );
}

fn timerReset() void {
    const cycles = getCycles();
    _ = sbi.setTimer(@intCast(cycles + board_cfg.timer.freq / HZ));
    io.setCsr("sie", SIE_STIE);

    return;
}

pub fn timerInit() void {
    return timerReset();
}

pub fn handleTimerIrq() void {
    io.clearCsr("sie", SIE_STIE);
    timerReset();

    const proc = @import("task.zig").proc;
    ticks_lock.acquire();
    _ = jiffies.increment();
    proc.wakeup(@intCast(@intFromPtr(&jiffies)));
    ticks_lock.release();
}
