const std = @import("std");

/// SBI function IDs
const SBI_CONSOLE_PUTCHAR: u64 = 0x1;
const SBI_SET_TIMER: u64 = 0x0;
const SBI_CONSOLE_GETCHAR: u64 = 0x2;
const SBI_EXT_HSM: u64 = 0x48534D;
const SBI_EXT_IPI: u64 = 0x735049;
const SBI_EXT_PFENCE: u64 = 0x52464E;

const sbiExtHsmFid = enum {
    SBI_EXT_HSM_HART_START,
    SBI_EXT_HSM_HART_STOP,
    SBI_EXT_HSM_HART_STATUS,
    SBI_EXT_HSM_HART_SUSPEND,
};

/// Error type for SBI operations
pub const SbiError = error{
    UnsupportedFunction,
    InvalidParameter,
    InternalFailure,
};

/// Perform an SBI call with proper error handling
fn sbi_ecall(eid: u64, fid: u64, arg0: u64, arg1: u64, arg2: u64) u64 {
    // Zig's inline assembly with proper constraints
    return asm volatile (
        "ecall"
        : [res] "={a0}" (-> u64)
        : [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [fid] "{a6}" (fid),
          [eid] "{a7}" (eid)
        : .{ .memory = true });
}

pub fn hart_start(hartid: u64, start_addr: u64, p_opaque: u64) u64 {
    return sbi_ecall(SBI_EXT_HSM, @intFromEnum(sbiExtHsmFid.SBI_EXT_HSM_HART_START),
                    hartid, start_addr, p_opaque);
}

pub fn hart_stop() void {
    _ = sbi_ecall(SBI_EXT_HSM, @intFromEnum(sbiExtHsmFid.SBI_EXT_HSM_HART_STOP), 0, 0, 0);
}

pub fn hart_status(hartid: u64) u64 {
    return sbi_ecall(SBI_EXT_HSM, @intFromEnum(sbiExtHsmFid.SBI_EXT_HSM_HART_STATUS),
            hartid, 0, 0);
}

pub fn send_ipi(hart_mask: u64) u64 {
    return sbi_ecall(SBI_EXT_IPI, 0, hart_mask, 0, 0);
}

/// Set the timer for the next interrupt
pub fn setTimer(time: u64) u64 {
    // Timer setting doesn't return error codes in standard SBI
    return sbi_ecall(SBI_SET_TIMER, 0, time, 0, 0);
}

/// Write a character to the console
pub fn putChar(ch: u8) void {
    // Console putchar doesn't return error codes
    _ = sbi_ecall(SBI_CONSOLE_PUTCHAR, 0, ch, 0, 0);
}

/// Read a character from the console
pub fn getChar() ?u8 {
    const res = sbi_ecall(SBI_CONSOLE_GETCHAR, 0, 0, 0, 0);
    // Return null if no character available
    return if (res != 0) @as(u8, @truncate(res)) else null;
}
