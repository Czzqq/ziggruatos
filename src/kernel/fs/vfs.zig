const std = @import("std");

const device = @import("device");

const kprint = @import("common").utils.kprint;

// file system error types
pub const VfsError = error{
    PathNotFound,
    InvalidPath,
    NotInitialized,
    NotImplemented,
    InvalidFileType,
    AccessDenied,
    AlreadyExists,
};

// file system file types
pub const FileType = enum {
    Regular,
    Directory,
    Device,
    Symlink,
    Unknown,
};

// open flags (POSIX standard)
pub const O_RDONLY: u32 = 0x0;
pub const O_WRONLY: u32 = 0x1;
pub const O_RDWR: u32 = 0x2;
pub const O_ACCMODE: u32 = 0x3;
pub const O_CREAT: u32 = 0x40;
pub const O_TRUNC: u32 = 0x200;
pub const O_APPEND: u32 = 0x400;
pub const O_DIRECTORY: u32 = 0x8000;

// file open modes
pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    directory: bool = false,
    mode: u32 = 0o644, // default permission for newly created files
};

pub const FileStat = struct {
    file_type: FileType,
    size: usize,
    mode: u32,
    inode: u64,
};

pub const Inode = struct {
    id: u64,
    file_type: FileType,
    size: usize,
    mode: u32, // permissions
    fs: *FileSystem, // mean which filesystem this inode belongs to
    fs_specific: ?*anyopaque, // filesystem specific data
    dev: ?*const device.Device, // device associated with this inode (if device file)

    pub fn init(id: u64, file_type: FileType, size: usize, mode: u32, fs: *FileSystem) Inode {
        return Inode{
            .id = id,
            .file_type = file_type,
            .size = size,
            .mode = mode,
            .fs = fs,
            .fs_specific = null,
            .dev = null,
        };
    }

    pub fn initDevice(id: u64, file_type: FileType, mode: u32, fs: *FileSystem, dev: *const device.Device) Inode {
        return Inode{
            .id = id,
            .file_type = file_type,
            .size = 0, // device files have no size
            .mode = mode,
            .fs = fs,
            .fs_specific = null,
            .dev = dev,
        };
    }
};

// directory entry structure
pub const Dentry = struct {
    name: []const u8,
    inode: *Inode, // related inode number
    parent: ?*Dentry,
    children: std.ArrayList(*Dentry),
    ref_count: usize,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, inode: *Inode, parent: ?*Dentry) !*Dentry {
        const dentry = try allocator.create(Dentry);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        dentry.* = Dentry{
            .name = name_copy,
            .inode = inode,
            .parent = parent,
            .children = try std.ArrayList(*Dentry).initCapacity(allocator, 0),
            .ref_count = 1,

            .allocator = allocator,
        };
        return dentry;
    }

    pub fn deinit(self: *Dentry) void {
        // Free the copied name
        self.allocator.free(self.name);

        // Deinit children list
        self.children.deinit(self.allocator);

        // Free the dentry itself
        self.allocator.destroy(self);
    }

    pub fn add_chlid(self: *Dentry, child: *Dentry) !void {
        try self.children.append(self.allocator, child);
    }

    pub fn add_child(self: *Dentry, child: *Dentry) !void {
        try self.children.append(self.allocator, child);
    }

    pub fn find_child(self: *Dentry, name: []const u8) ?*Dentry {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }
};

// opened file structure
pub const File = struct {
    inode: *Inode,
    dentry: *Dentry,
    flags: OpenFlags,
    offset: usize, // current file offset
    ref_count: usize, // reference count

    pub fn read(self: *File, buffer: []u8) !usize {
        if (self.inode.dev) |dev| {
            // Handle device file read
            if (dev.dev_type != .Char) {
                return error.NotImplemented; // Only char devices supported for now
            }
            return dev.ops.Char.read(dev.ctx, buffer, self.offset);
        } else {
            // Handle regular file read
            return self.inode.fs.ops.read(self.inode, buffer, self.offset);
        }
    }

    pub fn write(self: *File, buffer: []const u8) !usize {
        if (self.inode.dev) |dev| {
            // Handle device file write
            if (dev.dev_type != .Char) {
                return error.NotImplemented; // Only char devices supported for now
            }
            return dev.ops.Char.write(dev.ctx, buffer, self.offset);
        } else {
            // Handle regular file write
            return self.inode.fs.ops.write(self.inode, buffer, self.offset);
        }
    }

    pub fn seek(self: *File, offset: usize) void {
        self.offset = offset;
    }
};

// filesystem operations structure
pub const FileSystemOps = struct {
    // Inode operations
    lookup: *const fn (parent: *Inode, name: []const u8) anyerror!?*Inode,
    create: *const fn (parent: *Inode, name: []const u8, mode: u32) anyerror!*Inode,
    mkdir: *const fn (parent: *Inode, name: []const u8, mode: u32) anyerror!*Inode,
    unlink: *const fn (parent: *Inode, name: []const u8) anyerror!void,

    // data operations
    read: *const fn (inode: *Inode, buffer: []u8, offset: usize) anyerror!usize,
    write: *const fn (inode: *Inode, buffer: []const u8, offset: usize) anyerror!usize,

    readdir: *const fn (inode: *Inode, index: usize) anyerror!?DirEntry,
};

pub const DirEntry = struct {
    name: []const u8,
    inode_id: u64,
    file_type: FileType,
};

pub const FileSystem = struct {
    name: []const u8,
    ops: FileSystemOps,
    root_inode: *Inode,
    superblock: ?*anyopaque, // superblock specific FileSystem data
};

pub const MountPoint = struct {
    path: []const u8,
    fs: *FileSystem,
};

pub const MAX_FD = 32;
const MAX_MOUNT_POINTS = 16;

pub const VFS = struct {
    allocator: std.mem.Allocator,
    root_dentry: *Dentry, // root directory entry "/"
    mount_points: std.ArrayList(MountPoint),

    initialized: bool,

    pub fn init(allocator: std.mem.Allocator) !*VFS {
        const vfs = try allocator.create(VFS);

        vfs.* = .{
            .allocator = allocator,
            .root_dentry = undefined,
            .mount_points = try std.ArrayList(MountPoint).initCapacity(allocator, 0),
            .initialized = false,
        };

        return vfs;
    }

    pub fn setup_root(self: *VFS, root_fs: *FileSystem) !void {
        self.root_dentry = try Dentry.init(self.allocator, "/", root_fs.root_inode, null);

        // mount root filesystem to '/'
        try self.mount_points.append(self.allocator, .{
            .path = "/",
            .fs = root_fs,
        });

        self.initialized = true;

        kprint("VFS root setup complete, Root Filesystem mounted at /\n", .{});
    }

    pub fn mknod(self: *VFS, path: []const u8, mode: u32, dev: u32) !void {
        // split directory and name
        const last_slash = std.mem.lastIndexOf(u8, path, "/");
        const parent_path = if (last_slash) |ls| if (ls == 0) "/" else path[0..ls] else "/";
        const filename = if (last_slash) |ls| path[ls + 1 ..] else path;

        // lookup parent directory
        const parent_dentry = try self.path_lookup(parent_path, false, null);
        if (parent_dentry == null) return error.PathNotFound;

        // Check if this is a device node
        const S_IFCHR = 0x100000; // Character device type
        const S_IFBLK = 0x060000; // Block device type

        if ((mode & S_IFCHR) == S_IFCHR or (mode & S_IFBLK) == S_IFBLK) {
            // Convert dev number to device pointer using registry
            const device_ptr = device.byNumber(device.DevNumber.decode(dev)) orelse return error.DeviceNotFound;
            // Use existing createDeviceNode which properly handles device nodes
            try self.createDeviceNode(path, mode, device_ptr);
        } else {
            // Handle regular file creation
            const new_inode = try parent_dentry.?.inode.fs.ops.create(parent_dentry.?.inode, filename, mode);
            const new_dentry = try Dentry.init(self.allocator, filename, new_inode, parent_dentry);
            try parent_dentry.?.add_child(new_dentry);
        }
    }

    pub fn mkdir(self: *VFS, path: []const u8) !void {
        // split directory and name
        const last_slash = std.mem.lastIndexOf(u8, path, "/");
        const parent_path = if (last_slash) |ls| if (ls == 0) "/" else path[0..ls] else "/";
        const dirname = if (last_slash) |ls| path[ls + 1 ..] else path;

        // lookup parent directory
        const parent_dentry = try self.path_lookup(parent_path, false, null);
        if (parent_dentry == null) return error.PathNotFound;

        // Check if directory already exists
        const existing = self.path_lookup(path, false, null) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (existing != null) {
            return error.AlreadyExists;
        }

        // create new directory
        const new_inode = try parent_dentry.?.inode.fs.ops.mkdir(parent_dentry.?.inode, dirname, 0o755);

        // create dentry
        const new_dentry = try Dentry.init(self.allocator, dirname, new_inode, parent_dentry);
        try parent_dentry.?.add_child(new_dentry);
    }

    pub fn mount(self: *VFS, path: []const u8, fs: *FileSystem) !void {
        const mount_dentry = try self.path_lookup(path, true, null);
        if (mount_dentry == null) {
            return error.PathNotFound;
        }

        mount_dentry.?.inode = fs.root_inode;

        try self.mount_points.append(self.allocator, .{
            .path = path,
            .fs = fs,
        });

        kprint("VFS mounted filesystem {s} at {s}\n", .{ fs.name, path });
    }

    pub fn path_lookup(self: *VFS, path: []const u8, create_if_missing: bool, start_dentry: ?*Dentry) !?*Dentry {
        if (!self.initialized) return error.NotInitialized;

        // process root path
        if (std.mem.eql(u8, path, "/")) {
            return self.root_dentry;
        }

        const is_absolute = path.len > 0 and path[0] == '/';
        const clean_path = if (is_absolute) path[1..] else path;

        // Use start_dentry for relative paths, root_dentry for absolute paths
        var current = if (is_absolute) self.root_dentry else (start_dentry orelse self.root_dentry);
        var iter = std.mem.splitAny(u8, clean_path, "/");

        while (iter.next()) |component| {
            if (component.len == 0) continue;

            // check if current is directory
            if (current.inode.file_type != .Directory) {
                return error.NotADirectory;
            }

            if (current.find_child(component)) |child| {
                current = child;
                continue;
            }

            // dentry cache miss, find from file system
            const maybe_inode = try current.inode.fs.ops.lookup(current.inode, component);

            if (maybe_inode) |inode| {
                // create dentry and append to cache
                const new_dentry = try Dentry.init(self.allocator, component, inode, current);
                errdefer {
                    self.allocator.free(new_dentry.name);
                    new_dentry.children.deinit(self.allocator);
                    self.allocator.destroy(new_dentry);
                } // manual cleanup since it's not added to parent's children yet

                try current.add_child(new_dentry);
                current = new_dentry;
            } else {
                if (create_if_missing) {
                    return null; // caller will create this
                }
                return error.FileNotFound;
            }
        }

        return current;
    }

    pub fn open(self: *VFS, path: []const u8, flags: OpenFlags, start_dentry: ?*Dentry) !*File {
        const dentry = try self.path_lookup(path, flags.create, start_dentry);
        if (dentry == null) {
            if (flags.create) {
                // create_file currently returns FD, need to modify
                // For now, handle creation differently
                const last_slash = std.mem.lastIndexOf(u8, path, "/");
                const dir_path = if (last_slash) |ls| path[0..ls] else "/";
                const filename = if (last_slash) |ls| path[ls + 1 ..] else path;

                const parent_dentry = try self.path_lookup(if (dir_path.len == 0) "/" else dir_path, false, start_dentry);
                if (parent_dentry == null) return error.PathNotFound;

                const new_inode = try parent_dentry.?.inode.fs.ops.create(parent_dentry.?.inode, filename, flags.mode);
                const new_dentry = try Dentry.init(self.allocator, filename, new_inode, parent_dentry);
                errdefer {
                    self.allocator.free(new_dentry.name);
                    new_dentry.children.deinit(self.allocator);
                    self.allocator.destroy(new_dentry);
                }

                try parent_dentry.?.add_child(new_dentry);

                const file = try self.allocator.create(File);
                file.* = .{
                    .inode = new_inode,
                    .dentry = new_dentry,
                    .flags = flags,
                    .offset = 0,
                    .ref_count = 1,
                };
                return file;
            }
            return error.FileNotFound;
        }

        const file = try self.allocator.create(File);
        file.* = .{
            .inode = dentry.?.inode,
            .dentry = dentry.?,
            .flags = flags,
            .offset = if (flags.append) dentry.?.inode.size else 0,
            .ref_count = 1,
        };
        return file;
    }

    fn create_file(self: *VFS, path: []const u8, mode: u32, flags: OpenFlags) !usize {
        // desperate split path
        const last_slash = std.mem.lastIndexOf(u8, path, "/");
        const dir_path = if (last_slash) |ls| path[0..ls] else "/";
        const filename = if (last_slash) |ls| path[ls + 1 ..] else path;

        // lookup parent dentry
        const parent_dentry = try self.path_lookup(if (dir_path.len == 0) "/" else dir_path, false, null);
        if (parent_dentry == null) return error.PathNotFound;

        const new_inode = try parent_dentry.?.inode.fs.ops.create(parent_dentry.?.inode, filename, mode);

        const new_dentry = try Dentry.init(self.allocator, filename, new_inode, parent_dentry);
        try parent_dentry.?.add_child(new_dentry);

        const fd = try self.alloc_fd();
        const file = try self.allocator.create(File);
        file.* = .{
            .inode = new_inode,
            .dentry = new_dentry,
            .flags = flags,
            .offset = 0,
        };

        self.open_files[fd] = file;
        return fd;
    }

    pub fn stat(self: *VFS, path: []const u8) !FileStat {
        const dentry = try self.path_lookup(path, false, null);
        if (dentry == null) return error.FileNotFound;

        const inode = dentry.?.inode;
        return FileStat{
            .file_type = inode.file_type,
            .size = inode.size,
            .mode = inode.mode,
            .inode = inode.id,
        };
    }

    pub fn createDeviceNode(self: *VFS, path: []const u8, mode: u32, dev: *const device.Device) !void {
        // split directory and name
        const last_slash = std.mem.lastIndexOf(u8, path, "/");
        const parent_path = if (last_slash) |ls| if (ls == 0) "/" else path[0..ls] else "/";
        const filename = if (last_slash) |ls| path[ls + 1 ..] else path;

        // lookup parent directory
        const parent_dentry = try self.path_lookup(parent_path, false, null);
        if (parent_dentry == null) return error.PathNotFound;

        // create new device inode
        const new_inode = try self.allocator.create(Inode);
        new_inode.* = Inode.initDevice(@intFromPtr(new_inode), // use pointer as unique inode ID
            .Device, mode, parent_dentry.?.inode.fs, dev);

        // create dentry
        const new_dentry = try Dentry.init(self.allocator, filename, new_inode, parent_dentry);
        errdefer new_dentry.deinit(); // Use deinit() because we haven't added it to parent's children yet

        try parent_dentry.?.add_child(new_dentry);
    }

    pub fn remove(self: *VFS, path: []const u8) !void {
        // Split path into parent and filename
        const last_slash = std.mem.lastIndexOf(u8, path, "/");
        const parent_path = if (last_slash) |ls| if (ls == 0) "/" else path[0..ls] else "/";
        const filename = if (last_slash) |ls| path[ls + 1 ..] else path;

        // Lookup parent directory
        const parent_dentry = try self.path_lookup(parent_path, false, null);
        if (parent_dentry == null) return error.PathNotFound;

        // Call filesystem-specific unlink operation first
        try parent_dentry.?.inode.fs.ops.unlink(parent_dentry.?.inode, filename);

        // Find the child dentry to remove
        var child_dentry: ?*Dentry = null;
        var child_index: usize = std.math.maxInt(usize);

        for (parent_dentry.?.children.items, 0..) |d, idx| {
            if (std.mem.eql(u8, d.name, filename)) {
                child_dentry = d;
                child_index = idx;
                break;
            }
        }

        if (child_dentry == null) return error.FileNotFound;

        // Remove from parent's children list
        _ = parent_dentry.?.children.swapRemove(child_index);

        // Clean up the dentry
        child_dentry.?.deinit();
    }

    pub fn readdir(self: *VFS, path: []const u8) ![]DirEntry {
        const dentry = try self.path_lookup(path, false, null);
        if (dentry == null) return error.FileNotFound;

        if (dentry.?.inode.file_type != .Directory) {
            return error.NotADirectory;
        }

        var entries = try std.ArrayList(DirEntry).initCapacity(self.allocator, 0);
        var index: usize = 0;

        while (true) {
            const maybe_entry = try dentry.?.inode.fs.ops.readdir(dentry.?.inode, index);
            if (maybe_entry == null) break;
            try entries.append(self.allocator, maybe_entry.?);
            index += 1;
        }

        // Include files supplied by an in-memory overlay alongside disk entries.
        for (dentry.?.children.items) |child| {
            var already_listed = false;
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.name, child.name)) {
                    already_listed = true;
                    break;
                }
            }
            if (!already_listed) {
                try entries.append(self.allocator, .{
                    .name = child.name,
                    .inode_id = child.inode.id,
                    .file_type = child.inode.file_type,
                });
            }
        }

        return entries.toOwnedSlice(self.allocator);
    }
};

var global_vfs: ?*VFS = null;

pub fn get_vfs() *VFS {
    return global_vfs.?;
}

pub fn init_vfs(allocator: std.mem.Allocator, root_fs: *FileSystem) !void {
    global_vfs = try VFS.init(allocator);
    try global_vfs.?.setup_root(root_fs);
}
