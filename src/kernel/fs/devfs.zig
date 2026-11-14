const std = @import("std");
const device = @import("device");
const vfs = @import("vfs.zig");

const DevFsState = struct {
    allocator: std.mem.Allocator,
};

fn stateOf(inode: *vfs.Inode) *DevFsState {
    return @ptrCast(@alignCast(inode.fs.superblock.?));
}

fn devfsLookup(parent: *vfs.Inode, name: []const u8) !?*vfs.Inode {
    const dev = device.byName(name) orelse return null;

    const state = stateOf(parent);
    const inode = try state.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.initDevice(
        device.DevNumber.encode(dev.num),
        .Device,
        0o600,
        parent.fs,
        dev,
    );
    return inode;
}

fn devfsReaddir(_: *vfs.Inode, index: usize) !?vfs.DirEntry {
    const dev = device.get(index) orelse return null;
    return .{
        .name = dev.name,
        .inode_id = device.DevNumber.encode(dev.num),
        .file_type = .Device,
    };
}

fn unsupportedCreate(_: *vfs.Inode, _: []const u8, _: u32) anyerror!*vfs.Inode {
    return error.AccessDenied;
}

fn unsupportedUnlink(_: *vfs.Inode, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

fn unsupportedRead(_: *vfs.Inode, _: []u8, _: usize) anyerror!usize {
    return error.AccessDenied;
}

fn unsupportedWrite(_: *vfs.Inode, _: []const u8, _: usize) anyerror!usize {
    return error.AccessDenied;
}

pub fn mount(allocator: std.mem.Allocator) !*vfs.FileSystem {
    const state = try allocator.create(DevFsState);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator };

    const fs = try allocator.create(vfs.FileSystem);
    errdefer allocator.destroy(fs);

    const root = try allocator.create(vfs.Inode);
    errdefer allocator.destroy(root);

    root.* = vfs.Inode.init(0, .Directory, 0, 0o755, fs);

    fs.* = .{
        .name = "devfs",
        .root_inode = root,
        .superblock = state,
        .ops = .{
            .lookup = devfsLookup,
            .readdir = devfsReaddir,
            .create = unsupportedCreate,
            .mkdir = unsupportedCreate,
            .unlink = unsupportedUnlink,
            .read = unsupportedRead,
            .write = unsupportedWrite,
        },
    };
    return fs;
}
