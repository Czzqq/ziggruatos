const std = @import("std");

const block = @import("block");
const initramfs = @import("initramfs.zig");
const tmpfs = @import("tmpfs.zig");
const vfs = @import("vfs.zig");
const zfs = @import("zfs.zig");
const opts = @import("build_options");

const kprint = @import("common").utils.kprint;

pub const FsInitResult = struct {
    root_fs: *vfs.FileSystem,
    use_zfs: bool,
};

fn initTmpfsBackend(allocator: std.mem.Allocator) FsInitResult {
    kprint("Initializing tmpfs backend...\n", .{});

    initramfs.init();

    const root_fs = tmpfs.init_tmpfs(allocator, 4 * 1024 * 1024) catch unreachable;

    return .{
        .root_fs = root_fs,
        .use_zfs = false,
    };
}

fn initZfsRootBackend(allocator: std.mem.Allocator, blk: *block.BlockDevice) FsInitResult {
    kprint("Initializing ZFS root backend...\n", .{});

    initramfs.init();

    kprint("Block device initialized, attempting to mount ZFS as root...\n", .{});
    if (zfs.mountZFSRoot(allocator, blk)) |zfs_fs| {
        kprint("Successfully mounted ZFS as root filesystem\n", .{});
        return .{
            .root_fs = zfs_fs,
            .use_zfs = true,
        };
    }

    kprint("Failed to mount ZFS, falling back to tmpfs\n", .{});
    const root_fs = tmpfs.init_tmpfs(allocator, 4 * 1024 * 1024) catch unreachable;

    return .{
        .root_fs = root_fs,
        .use_zfs = false,
    };
}

pub fn initFilesystem(allocator: std.mem.Allocator, blk: ?*block.BlockDevice) !FsInitResult {
    if (opts.fs_zfs_root) {
        return initZfsRootBackend(allocator, blk orelse return error.BlockDeviceRequired);
    }
    return initTmpfsBackend(allocator);
}

pub fn populateRoot(fs_info: FsInitResult) void {
    if (fs_info.use_zfs) {
        kprint("Populating ZFS root filesystem...\n", .{});
        zfs.populateZFSRoot();

        const exposed = initramfs.exposeMissingRootFiles(vfs.get_vfs()) catch |err| {
            kprint("Failed to expose initramfs files in root: {}\n", .{err});
            return;
        };
        kprint("Exposed {} initramfs files in root\n", .{exposed});
    } else {
        kprint("Populating tmpfs from initramfs...\n", .{});
        initramfs.populate_rootfs_from_initramfs() catch unreachable;
    }
}

pub fn ensureDevMountpoint() !void {
    vfs.get_vfs().mkdir("/dev") catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
}
