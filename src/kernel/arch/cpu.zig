const std = @import("std");

pub const riscv = @import("riscv.zig");

const MAX_CPUS = @import("board").config.max_cpus;

// Per-CPU struct
pub const PerCpu = struct {
    hartid: u32,

    // turn off interrupt counting and record
    // whether the erminal is opened
    // before entering the critical section
    noff: u32 = 0,
    intena: bool = false,

    var cpus: [MAX_CPUS]PerCpu = undefined;

    pub fn currentCpu() *PerCpu {
        const p = riscv.riscvReadTp();
        return @ptrCast(&cpus[p]);
    }

    pub fn alloc(id: u32) !*PerCpu {
        // const p = memory.kalloc(PerCpu, 1) catch |err| {
        //     kprint("alloc failed: {}\n", .{err});
        //     return err;
        // };
        if (id >= MAX_CPUS) {
            return error.InvalidAddress;
        }
        var p = &cpus[id];

        @memset(std.mem.asBytes(p), 0);

        p.hartid = id;

        return p;
    }

    pub fn getId() usize {
        return riscv.riscvReadTp();
    }
};
