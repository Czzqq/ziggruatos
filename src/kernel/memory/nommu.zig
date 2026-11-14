pub fn initialize(comptime Manager: type, _: anytype) !Manager {
    return .{};
}

pub fn fence() void {}
