const std = @import("std");

// Device Number
pub const DevNumber = struct {
    major: u16,
    minor: u16,

    pub fn encode(self: DevNumber) u32 {
        return (@as(u32, self.major) << 16) | @as(u32, self.minor);
    }

    pub fn decode(num: u32) DevNumber {
        return .{
            .major = @as(u16, @truncate(num >> 16)),
            .minor = @as(u16, @truncate(num))
        };
    }
};

// Device types
pub const Kind = enum {
    Char,
    Block,
};

// Character device operations
pub const CharOps = struct {
    read: *const fn (dev: *anyopaque, buffer: []u8, offset: usize) anyerror!usize,
    write: *const fn (dev: *anyopaque, buffer: []const u8, offset: usize) anyerror!usize,
};

// Block device operations
pub const BlockOps = struct {
    read: *const fn (dev: *anyopaque, block: usize, buffer: []u8) anyerror!usize,
    write: *const fn (dev: *anyopaque, block: usize, buffer: []const u8) anyerror!usize,
    flush: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    block_size: usize,
    block_count: u64,
};

// Device structure
pub const Device = struct {
    num: DevNumber,
    dev_type: Kind,
    name: []const u8,
    ctx: *anyopaque,
    ops: union(Kind) {
        Char: CharOps,
        Block: BlockOps,
    },
};

const MAX_DEVICES = 32;
var devices: [MAX_DEVICES]?*const Device = @splat(null);
var device_count: usize = 0;

pub fn init() void {
    device_count = 0;
    @memset(&devices, null);
}

pub fn register(dev: *const Device) !void {
    if (device_count == MAX_DEVICES)
        return error.RegistryFull;

    if (byNumber(dev.num) != null) return error.DeviceNumberExists;
    if (byName(dev.name) != null) return error.DeviceNameExists;

    devices[device_count] = dev;
    device_count += 1;
}

pub fn byNumber(num: DevNumber) ?*const Device {
    for (devices[0..device_count]) |may| {
        if (may) |dev| {
            if (dev.num.major == num.major and dev.num.minor == num.minor)
                return dev;
        }
    }
    return null;
}

pub fn byName(name: []const u8) ?*const Device {
    for (devices[0..device_count]) |may| {
        if (may) |dev| {
            if (std.mem.eql(u8, dev.name, name)) return dev;
        }
    }
    return null;
}

pub fn count() usize {
    return device_count;
}

pub fn get(index: usize) ?*const Device {
    if (index >= device_count) return null;
    return devices[index];
}
