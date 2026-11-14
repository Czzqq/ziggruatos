const utils = @import("common").utils;
const riscv = @import("riscv.zig");
const PerCpu = @import("cpu.zig").PerCpu;

pub fn pushoff() void {
    const cpu = PerCpu.currentCpu();
    const old = riscv.archLocalIrqState();

    riscv.archLocalIrqDisable();

    if (cpu.noff == 0) {
        cpu.intena = old;
    }
    cpu.noff += 1;
}

pub fn popoff() void {
    const cpu = PerCpu.currentCpu();

    if (riscv.archLocalIrqState()) {
        @panic("popoff: interruptible");
    }
    if (cpu.noff < 1) {
        @panic("popoff: noff < 1");
    }

    cpu.noff -= 1;
    if (cpu.noff == 0 and cpu.intena) {
        riscv.archLocalIrqEnable();
    }
}

pub const SpinLock = struct {
    locked: bool = false,
    name: []const u8,
    cpu: ?*PerCpu = null,

    pub fn init(name: []const u8) SpinLock {
        return .{
            .locked = false,
            .name = name,
            .cpu = null,
        };
    }

    pub fn acquire(self: *SpinLock) void {
        pushoff();
        if (self.holding()) {
            @panic("acquire: already holding lock");
        }

        while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {}

        self.cpu = PerCpu.currentCpu();
    }

    pub fn release(self: *SpinLock) void {
        if (!self.holding()) {
            @panic("release: not holding lock");
        }
        self.cpu = null;

        @atomicStore(bool, &self.locked, false, .release);

        popoff();
    }

    pub fn holding(self: *SpinLock) bool {
        return @atomicLoad(bool, &self.locked, .acquire) and self.cpu == PerCpu.currentCpu();
    }
};
