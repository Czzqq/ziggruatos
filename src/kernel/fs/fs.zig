const std = @import("std");

pub const initramfs = @import("initramfs.zig");
pub const tmpfs = @import("tmpfs.zig");
pub const vfs = @import("vfs.zig");
pub const zfs = @import("zfs.zig");
pub const devfs = @import("devfs.zig");
pub const bootstrap = @import("bootstrap.zig");

const opts = @import("build_options");

pub const FsBackend = enum {
    Tmpfs,
    ZfsRoot,
};

pub const Config = struct {
    pub const use_tmpfs: bool = opts.fs_tmpfs;
    pub const use_zfs_root: bool = opts.fs_zfs_root;
    pub const copy_to_zfs: bool = opts.copy_to_zfs;

    pub const fs_backend: FsBackend = if (use_zfs_root)
        .ZfsRoot
    else
        .Tmpfs;
};
