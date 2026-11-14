const std = @import("std");
const vfs = @import("vfs.zig");

const board_cfg = @import("board").config;

const kprint = @import("common").utils.kprint;
const embedded_blob = if (board_cfg.initramfs.embedded)
    @import("initramfs_blob")
else
    struct {};

const CpioNewcHeader = extern struct {
    magic: [6]u8,
    ino: [8]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    nlink: [8]u8,
    mtime: [8]u8,
    filesize: [8]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    rdevmajor: [8]u8,
    rdevminor: [8]u8,
    namesize: [8]u8,
    check: [8]u8,
};

pub const FileEntry = struct {
    name: []const u8,
    data: []const u8,
    mode: u32,
};

var initramfs_start: [*]u8 = undefined;
var initrafs_end: [*]u8 = undefined;
var file_table: [256]FileEntry = undefined;
var file_count: usize = 0;
var initialized: bool = false;
var root_overlay_fs: vfs.FileSystem = undefined;

fn overlayLookup(_: *vfs.Inode, _: []const u8) anyerror!?*vfs.Inode {
    return null;
}

fn overlayCreate(_: *vfs.Inode, _: []const u8, _: u32) anyerror!*vfs.Inode {
    return error.AccessDenied;
}

fn overlayUnlink(_: *vfs.Inode, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

fn overlayRead(inode: *vfs.Inode, buffer: []u8, offset: usize) anyerror!usize {
    const entry: *const FileEntry = @ptrCast(@alignCast(inode.fs_specific.?));
    if (offset >= entry.data.len) return 0;
    const count = @min(buffer.len, entry.data.len - offset);
    @memcpy(buffer[0..count], entry.data[offset..][0..count]);
    return count;
}

fn overlayWrite(_: *vfs.Inode, _: []const u8, _: usize) anyerror!usize {
    return error.AccessDenied;
}

fn overlayReaddir(_: *vfs.Inode, _: usize) anyerror!?vfs.DirEntry {
    return error.NotADirectory;
}

fn exposeRootFile(v: *vfs.VFS, entry: *FileEntry) !void {
    const inode = try v.allocator.create(vfs.Inode);
    errdefer v.allocator.destroy(inode);
    inode.* = vfs.Inode.init(@intFromPtr(entry), .Regular, entry.data.len, entry.mode & 0o777, &root_overlay_fs);
    inode.fs_specific = @ptrCast(entry);

    const dentry = try vfs.Dentry.init(v.allocator, entry.name, inode, v.root_dentry);
    errdefer dentry.deinit();
    try v.root_dentry.add_child(dentry);
}

/// Expose initramfs programs missing from the ZFS root as read-only VFS files.
/// Their bytes remain in initramfs instead of consuming ZFS data blocks.
pub fn exposeMissingRootFiles(v: *vfs.VFS) !usize {
    if (!initialized) init();

    root_overlay_fs = .{
        .name = "initramfs-overlay",
        .ops = .{
            .lookup = overlayLookup,
            .create = overlayCreate,
            .mkdir = overlayCreate,
            .unlink = overlayUnlink,
            .read = overlayRead,
            .write = overlayWrite,
            .readdir = overlayReaddir,
        },
        .root_inode = v.root_dentry.inode,
        .superblock = null,
    };

    var added: usize = 0;
    for (file_table[0..file_count]) |*entry| {
        if (std.mem.indexOfScalar(u8, entry.name, '/') != null) continue;

        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/{s}", .{entry.name});
        const existing = v.path_lookup(path, false, null) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing != null) continue;

        try exposeRootFile(v, entry);
        added += 1;
    }
    return added;
}

fn parseHex(str: []const u8) u32 {
    var result: u32 = 0;
    for (str) |c| {
        result <<= 4;
        if (c >= '0' and c <= '9') {
            result |= c - '0';
        } else if (c >= 'a' and c <= 'f') {
            result |= c - 'a' + 10;
        } else if (c >= 'A' and c <= 'F') {
            result |= c - 'A' + 10;
        }
    }
    return result;
}

fn alignUp(addr: usize, align_to: usize) usize {
    return (addr + align_to - 1) & ~(align_to - 1);
}

pub fn init() void {
    if (initialized) return;

    kprint("Initialized Initramfs\n", .{});

    const initramfs_limit: usize = if (comptime board_cfg.initramfs.embedded) blk: {
        const blob = embedded_blob.bytes;
        initramfs_start = @ptrCast(@constCast(blob.ptr));
        break :blk @intFromPtr(blob.ptr) + blob.len;
    } else blk: {
        initramfs_start = @ptrFromInt(board_cfg.initramfs.base);
        break :blk board_cfg.initramfs.base + board_cfg.initramfs.max_size;
    };

    const header = @as(*const CpioNewcHeader, @ptrCast(@alignCast(initramfs_start)));
    if (!std.mem.eql(u8, &header.magic, "070701")) {
        kprint("ERROR: Invalid CPIO magic {x} at initramfs base\n", .{header.magic});
        return;
    }

    var ptr: [*]u8 = initramfs_start;
    var entries_found: usize = 0;

    while (@intFromPtr(ptr) < initramfs_limit) {
        const h = @as(*const CpioNewcHeader, @ptrCast(@alignCast(ptr)));

        if (!std.mem.eql(u8, &h.magic, "070701")) {
            kprint("WARNING: Invalid magic encountered, stopping parse\n", .{});
            break;
        }

        const namesize = parseHex(&h.namesize);
        const filesize = parseHex(&h.filesize);
        const mode = parseHex(&h.mode);

        ptr += @sizeOf(CpioNewcHeader);

        // reading file name
        const name_ptr = ptr;
        const name = name_ptr[0 .. namesize - 1]; // skip 'null' at tail

        ptr += namesize;
        ptr = @ptrFromInt(alignUp(@intFromPtr(ptr), 4));

        // check TRAILER
        if (std.mem.eql(u8, name, "TRAILER!!!")) {
            initrafs_end = ptr;
            break;
        }

        // retrieve file data
        const file_data = ptr[0..filesize];
        const file_type = mode & 0o170000;

        if (file_type == 0o100000) {
            // S_IFREG
            if (file_count < file_table.len) {
                file_table[file_count] = FileEntry{
                    .name = name,
                    .data = file_data,
                    .mode = mode,
                };

                kprint("[{}]{} ({})bytes, mode: 0{o}\n", .{ file_count, name, filesize, mode & 0o777 });
                file_count += 1;
                entries_found += 1;
            } else {
                kprint("WARNING: File table full, ignoring: {}\n", .{name});
            }
        }

        ptr += filesize;
        ptr = @ptrFromInt(alignUp(@intFromPtr(ptr), 4));
    }

    const size = @intFromPtr(initrafs_end) - @intFromPtr(initramfs_start);
    kprint("Total size: {}bytes, {}KB Files found: {}\n", .{ size, size / 1024, file_count });

    initialized = true;
}

pub fn findFile(path: []const u8) ?FileEntry {
    if (!initialized) {
        kprint("ERROR: initramfs not initialized\n", .{});
        return null;
    }

    const clean_path = if (path.len > 0 and path[0] == '/')
        path[1..]
    else
        path;

    for (file_table[0..file_count]) |entry| {
        if (std.mem.eql(u8, entry.name, clean_path)) {
            return entry;
        }
    }

    return null;
}

pub fn listFiles() void {
    if (!initialized) {
        kprint("ERROR: initramfs not initialized\n", .{});
        return;
    }

    kprint("Initramfs Contents\n", .{});
    for (file_table[0..file_count], 0..) |entry, i| {
        kprint("[{}] {} - {}bytes\n", .{ i, entry.name, entry.data.len });
    }
}

pub fn initramfsTest() void {
    listFiles();
    const file = findFile("exist").?;
    kprint("test file name: {}, data: {}\n", .{ file.name, file.data });
}

// create directories recursively
fn create_dirs_recursive(v: *vfs.VFS, path: []const u8, buffer: []u8) !void {
    _ = buffer;

    if (path.len <= 1) return;

    v.mkdir(path) catch |err| {
        switch (err) {
            error.FileExists => {
                return;
            },
            error.FileNotFound => {
                var parent_slash: ?usize = null;
                for (path, 0..) |c, i| {
                    if (c == '/' and i > 0) {
                        parent_slash = i;
                    }
                }

                if (parent_slash) |pos| {
                    const parent_path = path[0..pos];
                    var parent_buffer: [512]u8 = undefined;
                    try create_dirs_recursive(v, parent_path, &parent_buffer);
                    try v.mkdir(path);
                }
            },
            else => return err,
        }
    };
}

fn ensure_parent_dirs(v: *vfs.VFS, path: []const u8) !void {
    var last_slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/' and i > 0) {
            last_slash = i;
        }
    }

    if (last_slash == null or last_slash.? <= 0) {
        return;
    }

    const dir_path = path[0..last_slash.?];

    var dir_buffer: [512]u8 = undefined;
    try create_dirs_recursive(v, dir_path, &dir_buffer);
}

fn copy_file_to_vfs(v: *vfs.VFS, entry: *const FileEntry) !void {
    const full_path = entry.name;
    var path_buffer: [512]u8 = undefined;
    const path = if (full_path.len > 0 and full_path[0] == '/')
        full_path
    else blk: {
        const result = std.fmt.bufPrint(&path_buffer, "/{s}", .{full_path}) catch {
            kprint("ERROR: Path too long when copying to VFS: {}\n", .{full_path});
            return error.PathTooLong;
        };
        break :blk result;
    };

    try ensure_parent_dirs(v, path);

    const file = v.open(path, .{ .create = true, .write = true, .mode = entry.mode & 0o777 }, null) catch |err| {
        kprint("ERROR: Failed to open file in VFS: {} (err={})\n", .{ path, err });
        return err;
    };
    defer v.allocator.destroy(file);

    _ = file.write(entry.data) catch |err| {
        kprint("ERROR: Failed to write file data to VFS: {} (err={})\n", .{ path, err });
        return err;
    };
}

pub fn populate_rootfs_from_initramfs() !void {
    if (!initialized) {
        init();
    }

    const v = vfs.get_vfs();

    var success_count: usize = 0;
    for (file_table[0..file_count]) |entry| {
        copy_file_to_vfs(v, &entry) catch {
            kprint("Failed to copy file {} to VFS\n", .{entry.name});
            continue;
        };
        success_count += 1;
    }

    v.mkdir("/dev") catch |err| {
        kprint("Warning: Failed to create /dev: {}\n", .{err});
    };

    kprint("Files move tmpfs {}/{}\n", .{ success_count, file_count });
}

pub fn test_populate_rootfs() void {
    populate_rootfs_from_initramfs() catch {
        kprint("ERROR: Failed to populate rootfs from initramfs\n", .{});
        return;
    };

    // test one file
    blk1: {
        // status
        const v = vfs.get_vfs();

        const path: []const u8 = "/test2.txt";
        const fd = v.open(path, .{ .read = true }, null) catch |err| {
            kprint("Failed to open {s}: {}\n", .{ path, err });
            break :blk1; // Exit outer block after listing
        };
        defer v.close(fd) catch {};

        var read_buffer: [128]u8 = undefined;
        const read_bytes = v.read(fd, &read_buffer) catch |err| {
            kprint("Failed to read {s}: {}\n", .{ path, err });
            break :blk1;
        };
        kprint("\nRead {} bytes from {}:\n", .{ read_bytes, path });
        kprint("{s}\n", .{read_buffer[0..read_bytes]});
    }

    // test list root directory
    blk2: {
        kprint("\nRoot directory contents:\n", .{});
        const v = vfs.get_vfs();
        const entries = v.readdir("/") catch |e| {
            kprint("ERROR: Cannot read root directory: {}\n", .{e});
            break :blk2;
        };

        for (entries) |entry| {
            const type_str: []const u8 = if (entry.file_type == .Directory) "DIR" else "FILE";
            kprint("  [{s}] {s} (inode: {})\n", .{ type_str, entry.name, entry.inode_id });
        }

        kprint("\n/bin directory contents:\n", .{});
        const bin_entries = v.readdir("/bin") catch |e| {
            kprint("ERROR: Cannot read /bin: {}\n", .{e});
            break :blk2;
        };

        for (bin_entries) |entry| {
            const type_str = if (entry.file_type == .Directory) "DIR" else "FILE";
            kprint("  [{s}] {s} (inode: {})\n", .{ type_str, entry.name, entry.inode_id });
        }

        kprint("\n/doc directory contents:\n", .{});
        const doc_entries = v.readdir("/doc") catch |e| {
            kprint("ERROR: Cannot read /doc: {}\n", .{e});
            break :blk2;
        };

        for (doc_entries) |entry| {
            const type_str = if (entry.file_type == .Directory) "DIR" else "FILE";
            kprint("  [{s}] {s} (inode: {})\n", .{ type_str, entry.name, entry.inode_id });
        }
    }
}
