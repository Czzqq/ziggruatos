pub fn mmioRead(comptime T: type, addr: usize) T {
    const ptr = @as(*volatile T, @ptrFromInt(addr));

    return ptr.*;
}

pub fn mmioWrite(comptime T: type, value: T, addr: usize) void {
    const ptr = @as(*volatile T, @ptrFromInt(addr));
    ptr.* = value;
}

pub fn writeCsr(comptime csr: []const u8, val: u64) void {
    const asm_str = "csrw " ++ csr ++ ", %[val]";
    _ = asm volatile (asm_str
        :
        : [val] "r" (val),
        : .{ .memory = true });
}

pub fn readCsr(comptime csr: []const u8) u64 {
    const asm_str = "csrr %[ret], " ++ csr;

    return asm volatile (asm_str
        : [ret] "=r" (-> u64),
        :
        : .{ .memory = true });
}

pub fn clearCsr(comptime csr: []const u8, bit: u64) void {
    const asm_str = "csrc " ++ csr ++ ", %[bit]";
    asm volatile (asm_str
        :
        : [bit] "r" (bit),
        : .{ .memory = true });
}

pub fn setCsr(comptime csr: []const u8, bit: u64) void {
    const asm_str = "csrs " ++ csr ++ ", %[bit]";
    asm volatile (asm_str
        :
        : [bit] "r" (bit),
        : .{ .memory = true });
}
