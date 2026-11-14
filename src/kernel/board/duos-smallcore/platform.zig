pub const config = @import("config.zig");

pub inline fn cpu_to_context(cpu: usize) usize {
    return cpu * 2 + 1;
}
