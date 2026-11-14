const std = @import("std");
const vfs = @import("vfs.zig");

const kprint = @import("common").utils.kprint;

// ============================================================================
// tmpfs struct
// ============================================================================

/// tmpfs page
const TmpfsPage = struct {
    data: []u8, // 4KB
    dirty: bool,

    const PAGE_SIZE = 4096;

    pub fn alloc(allocator: std.mem.Allocator) !*TmpfsPage {
        const page = try allocator.create(TmpfsPage);
        page.data = try allocator.alloc(u8, PAGE_SIZE);
        page.dirty = false;
        return page;
    }

    pub fn free(self: *TmpfsPage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};

/// tmpfs file data（page array）
const TmpfsFileData = struct {
    pages: std.ArrayList(*TmpfsPage), // Page Array
    allocator: std.mem.Allocator,
    size: usize,

    pub fn init(allocator: std.mem.Allocator) TmpfsFileData {
        return .{
            .pages = std.ArrayList(*TmpfsPage).initCapacity(allocator, 0) catch {
                @panic("Failed to initialize TmpfsFileData pages array");
            },
            .allocator = allocator,
            .size = 0,
        };
    }

    pub fn deinit(self: *TmpfsFileData) void {
        for (self.pages.items) |page| {
            page.free(self.allocator);
        }
        self.pages.deinit(self.allocator);
    }

    /// read data
    pub fn read(self: *TmpfsFileData, buffer: []u8, offset: usize) !usize {
        var bytes_read: usize = 0;
        var current_offset = offset;

        if (offset >= self.size) {
            return 0;
        }

        const available = self.size - offset;
        const to_read = @min(buffer.len, available);

        while (bytes_read < to_read) {
            const page_index = current_offset / TmpfsPage.PAGE_SIZE;
            const page_offset = current_offset % TmpfsPage.PAGE_SIZE;

            // exceed file size
            if (page_index >= self.pages.items.len) break;

            const page = self.pages.items[page_index];
            const bytes_in_page = @min(to_read - bytes_read, TmpfsPage.PAGE_SIZE - page_offset);

            @memcpy(buffer[bytes_read .. bytes_read + bytes_in_page], page.data[page_offset .. page_offset + bytes_in_page]);

            bytes_read += bytes_in_page;
            current_offset += bytes_in_page;
        }

        return bytes_read;
    }

    /// write data（alloc new page）
    pub fn write(self: *TmpfsFileData, data: []const u8, offset: usize) !usize {
        var bytes_written: usize = 0;
        var current_offset = offset;

        while (bytes_written < data.len) {
            const page_index = current_offset / TmpfsPage.PAGE_SIZE;
            const page_offset = current_offset % TmpfsPage.PAGE_SIZE;

            // if page not exist, alloc new page
            while (page_index >= self.pages.items.len) {
                const new_page = try TmpfsPage.alloc(self.allocator);
                @memset(new_page.data, 0); // zero initialize
                try self.pages.append(self.allocator, new_page);
            }

            const page = self.pages.items[page_index];
            const bytes_in_page = @min(data.len - bytes_written, TmpfsPage.PAGE_SIZE - page_offset);

            @memcpy(page.data[page_offset .. page_offset + bytes_in_page], data[bytes_written .. bytes_written + bytes_in_page]);

            page.dirty = true;
            bytes_written += bytes_in_page;
            current_offset += bytes_in_page;
        }

        const new_size = offset + bytes_written;
        if (new_size > self.size) {
            self.size = new_size;
        }

        return bytes_written;
    }

    /// truncate file to new_size
    pub fn truncate(self: *TmpfsFileData, new_size: usize) !void {
        const new_page_count = (new_size + TmpfsPage.PAGE_SIZE - 1) / TmpfsPage.PAGE_SIZE;

        // release extra pages
        while (self.pages.items.len > new_page_count) {
            const page = self.pages.pop();
            page.free(self.allocator);
        }

        // if need, zero out the tail of the last page
        if (new_page_count > 0 and self.pages.items.len == new_page_count) {
            const last_page = self.pages.items[self.pages.items.len - 1];
            const offset_in_last_page = new_size % TmpfsPage.PAGE_SIZE;
            if (offset_in_last_page > 0) {
                @memset(last_page.data[offset_in_last_page..], 0);
            }
        }

        self.size = new_size;
    }

    pub fn get_size(self: *TmpfsFileData) usize {
        return self.size;
    }

    // retrieve number of bytes used by this file data
    pub fn memory_usage(self: *TmpfsFileData) usize {
        return self.pages.items.len * TmpfsPage.PAGE_SIZE;
    }
};

/// tmpfs inode data
const TmpfsInodeData = struct {
    file_type: vfs.FileType,
    file_data: ?TmpfsFileData, // if regular file
    children: ?std.StringHashMap(*vfs.Inode), // if directory file
    allocator: std.mem.Allocator,

    pub fn init_file(allocator: std.mem.Allocator) !*TmpfsInodeData {
        const data = try allocator.create(TmpfsInodeData);
        data.* = .{
            .file_type = .Regular,
            .file_data = TmpfsFileData.init(allocator),
            .children = null,
            .allocator = allocator,
        };
        return data;
    }

    pub fn init_dir(allocator: std.mem.Allocator) !*TmpfsInodeData {
        const data = try allocator.create(TmpfsInodeData);
        data.* = .{
            .file_type = .Directory,
            .file_data = null,
            .children = std.StringHashMap(*vfs.Inode).init(allocator),
            .allocator = allocator,
        };
        return data;
    }

    pub fn deinit(self: *TmpfsInodeData) void {
        if (self.file_data) |*fd| {
            fd.deinit();
        }

        if (self.children) |*ch| {
            var iter = ch.iterator();
            while (iter.next()) |entry| {
                // Free the copied name string
                self.allocator.free(entry.key_ptr.*);
                // Destroy the inode
                self.allocator.destroy(entry.value_ptr.*);
            }
            ch.deinit();
        }
        self.allocator.destroy(self);
    }
};

/// tmpfs super block
const TmpfsSuperblock = struct {
    allocator: std.mem.Allocator,
    next_inode_id: u64,
    total_inodes: usize,
    total_blocks: usize, // haved used pages
    max_blocks: usize, // max pages allowed

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !*TmpfsSuperblock {
        const sb = try allocator.create(TmpfsSuperblock);
        sb.* = .{
            .allocator = allocator,
            .next_inode_id = 1,
            .total_inodes = 0,
            .total_blocks = 0,
            .max_blocks = max_size / TmpfsPage.PAGE_SIZE,
        };
        return sb;
    }
};

// ============================================================================
// tmpfs file system ops
// ============================================================================

fn tmpfs_lookup(parent: *vfs.Inode, name: []const u8) !?*vfs.Inode {
    const parent_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));

    if (parent_data.file_type != .Directory) return error.NotADirectory;

    if (parent_data.children) |*children| {
        return children.get(name);
    }

    return null;
}

fn tmpfs_create(parent: *vfs.Inode, name: []const u8, mode: u32) !*vfs.Inode {
    const sb = @as(*TmpfsSuperblock, @ptrCast(@alignCast(parent.fs.superblock.?)));
    const parent_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));

    if (parent_data.file_type != .Directory) return error.NotADirectory;

    const name_copy = try sb.allocator.dupe(u8, name);
    errdefer sb.allocator.free(name_copy);

    // create new inode
    const new_inode = try sb.allocator.create(vfs.Inode);
    errdefer sb.allocator.destroy(new_inode);

    const inode_data = try TmpfsInodeData.init_file(sb.allocator);
    errdefer inode_data.deinit();

    new_inode.* = vfs.Inode.init(
        sb.next_inode_id,
        .Regular,
        0,
        mode,
        parent.fs,
    );
    new_inode.fs_specific = inode_data;

    sb.next_inode_id += 1;
    sb.total_inodes += 1;

    // append to parent directory
    if (parent_data.children) |*children| {
        try children.put(name_copy, new_inode);
    }

    return new_inode;
}

fn tmpfs_mkdir(parent: *vfs.Inode, name: []const u8, mode: u32) !*vfs.Inode {
    const sb = @as(*TmpfsSuperblock, @ptrCast(@alignCast(parent.fs.superblock.?)));
    const parent_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));

    if (parent_data.file_type != .Directory) return error.NotADirectory;

    const name_copy = try sb.allocator.dupe(u8, name);
    errdefer sb.allocator.free(name_copy);

    // create directory inode
    const new_inode = try sb.allocator.create(vfs.Inode);
    errdefer sb.allocator.destroy(new_inode);

    const inode_data = try TmpfsInodeData.init_dir(sb.allocator);
    errdefer inode_data.deinit();

    new_inode.* = vfs.Inode.init(
        sb.next_inode_id,
        .Directory,
        0,
        mode | 0o040000, // S_IFDIR
        parent.fs,
    );
    new_inode.fs_specific = inode_data;

    sb.next_inode_id += 1;
    sb.total_inodes += 1;

    // append to parent directory
    if (parent_data.children) |*children| {
        try children.put(name_copy, new_inode);
    }

    return new_inode;
}

fn tmpfs_read(inode: *vfs.Inode, buffer: []u8, offset: usize) !usize {
    const inode_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));

    if (inode_data.file_type != .Regular) return error.IsADirectory;

    if (inode_data.file_data) |*file_data| {
        return try file_data.read(buffer, offset);
    }

    return 0;
}

fn tmpfs_write(inode: *vfs.Inode, data: []const u8, offset: usize) !usize {
    const sb = @as(*TmpfsSuperblock, @ptrCast(@alignCast(inode.fs.superblock.?)));
    const inode_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));

    if (inode_data.file_type != .Regular) return error.IsADirectory;

    // check space limit
    const new_size = offset + data.len;
    const needed_pages = (new_size + TmpfsPage.PAGE_SIZE - 1) / TmpfsPage.PAGE_SIZE;

    if (sb.total_blocks + needed_pages > sb.max_blocks) {
        return error.NoSpaceLeft;
    }

    if (inode_data.file_data) |*file_data| {
        const old_pages = file_data.pages.items.len;
        const bytes_written = try file_data.write(data, offset);
        const new_pages = file_data.pages.items.len;

        // update stats
        sb.total_blocks += (new_pages - old_pages);

        // update inode size
        if (offset + bytes_written > inode.size) {
            inode.size = offset + bytes_written;
        }

        return bytes_written;
    }

    return 0;
}

fn tmpfs_unlink(parent: *vfs.Inode, name: []const u8) !void {
    const parent_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));

    if (parent_data.file_type != .Directory) return error.NotADirectory;

    if (parent_data.children) |*children| {
        // Remove the entry from children map
        if (children.fetchRemove(name)) |entry| {
            // Free the copied name string
            parent_data.allocator.free(entry.key);
            // Destroy the inode
            const inode = entry.value;
            const inode_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));
            inode_data.deinit();
            parent_data.allocator.destroy(inode);
        } else {
            return error.FileNotFound;
        }
    }
}

fn tmpfs_readdir(inode: *vfs.Inode, index: usize) !?vfs.DirEntry {
    const inode_data = @as(*TmpfsInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));

    if (inode_data.file_type != .Directory) return error.NotADirectory;

    if (inode_data.children) |*children| {
        var iter = children.iterator();
        var i: usize = 0;

        while (iter.next()) |entry| {
            if (i == index) {
                const child_inode = entry.value_ptr.*;
                return vfs.DirEntry{
                    .name = entry.key_ptr.*,
                    .inode_id = child_inode.id,
                    .file_type = child_inode.file_type,
                };
            }
            i += 1;
        }
    }

    return null;
}

// ============================================================================
// tmpfs initialization and test
// ============================================================================

pub fn init_tmpfs(allocator: std.mem.Allocator, max_size: usize) !*vfs.FileSystem {
    kprint("Initializing tmpfs (max size: {} MB)\n", .{max_size / (1024 * 1024)});

    const sb = try TmpfsSuperblock.init(allocator, max_size);

    const root_inode = try allocator.create(vfs.Inode);
    const root_data = try TmpfsInodeData.init_dir(allocator);

    const fs = try allocator.create(vfs.FileSystem);

    root_inode.* = vfs.Inode.init(0, .Directory, 0, 0o755, fs);
    root_inode.fs_specific = root_data;

    sb.total_inodes = 1;

    fs.* = .{
        .name = "tmpfs",
        .ops = .{
            .lookup = tmpfs_lookup,
            .create = tmpfs_create,
            .mkdir = tmpfs_mkdir,
            .unlink = tmpfs_unlink,
            .read = tmpfs_read,
            .write = tmpfs_write,
            .readdir = tmpfs_readdir,
        },
        .root_inode = root_inode,
        .superblock = sb,
    };

    kprint("tmpfs initialized successfully\n", .{});
    return fs;
}

/// retrieve tmpfs stats
pub fn tmpfs_statfs(fs: *vfs.FileSystem) !TmpfsStats {
    const sb = @as(*TmpfsSuperblock, @ptrCast(@alignCast(fs.superblock.?)));

    return TmpfsStats{
        .total_inodes = sb.total_inodes,
        .total_blocks = sb.total_blocks,
        .free_blocks = sb.max_blocks - sb.total_blocks,
        .block_size = TmpfsPage.PAGE_SIZE,
        .total_size = sb.max_blocks * TmpfsPage.PAGE_SIZE,
        .used_size = sb.total_blocks * TmpfsPage.PAGE_SIZE,
    };
}

pub const TmpfsStats = struct {
    total_inodes: usize,
    total_blocks: usize,
    free_blocks: usize,
    block_size: usize,
    total_size: usize,
    used_size: usize,
};

pub fn test_tmpfs(allocator: std.mem.Allocator) !void {
    var buffer: [256]u8 = undefined;

    // 1. tmpfs: init vfs and tmpfs
    kprint("\n--- Testing tmpfs (Read-Write) ---\n", .{});
    const tmpfs_fs = init_tmpfs(allocator, 10 * 1024 * 1024) catch return;
    try vfs.init_vfs(allocator, tmpfs_fs);
    const v = vfs.get_vfs();

    kprint("Mounted tmpfs as root filesystem, will mount /tmp\n", .{});

    // 2. create directory 'tmp' and mount
    v.mkdir("/tmp") catch return;
    // mount /tmp
    v.mount("/tmp", tmpfs_fs) catch return;

    // test write and read
    {
        // create new file
        const fd = v.open("/tmp/test.txt", .{ .create = true, .write = true }) catch |err| {
            kprint("Failed to create: {}\n", .{err});
            return;
        };

        // write data
        const write_data = "Hello from tmpfs!\n";
        const written = v.write(fd, write_data) catch 0;
        kprint("Written fd {} {} bytes to tmpfs\n", .{ fd, written });
        v.close(fd) catch {};

        // read back
        const fd2 = v.open("/tmp/test.txt", .{ .read = true }) catch return;
        const read_bytes = v.read(fd2, &buffer) catch 0;
        kprint("Read back: {s}\n", .{buffer[0..read_bytes]});
        v.close(fd2) catch {};
    }

    // create directory
    v.mkdir("/tmp/mydir") catch |err| {
        kprint("mkdir error: {}\n", .{err});
    };

    // test write and seed read
    {
        // create file to nested directory
        const fd = v.open("/tmp/mydir/file2.txt", .{ .create = true, .write = true, .read = true }) catch return;
        const write_data = "Hello Nested file\n";
        const written = v.write(fd, write_data) catch 0;
        kprint("Written fd {} {} bytes to tmpfs\n", .{ fd, written });
        v.seek(fd, 0) catch return;
        const read_bytes = v.read(fd, &buffer) catch 0;
        kprint("Direct Read back: {s}\n", .{buffer[0..read_bytes]});
        v.close(fd) catch {};
    }

    {
        const fd = v.open("/tmp/mydir/file2.txt", .{ .read = true }) catch return;
        const read_bytes = v.read(fd, &buffer) catch 0;
        kprint("Read back: {s}\n", .{buffer[0..read_bytes]});
        v.close(fd) catch {};
    }

    // status
    const stats = tmpfs_statfs(tmpfs_fs) catch return;
    kprint("\ntmpfs Statistics:\n", .{});
    kprint("  Total inodes: {}\n", .{stats.total_inodes});
    kprint("  Used size: {} bytes\n", .{stats.used_size});
    kprint("  Free size: {} bytes\n", .{stats.total_size - stats.used_size});
}
