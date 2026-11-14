const std = @import("std");

const device = @import("device");

const drivers = @import("drivers");
const virtio = drivers.virtio;
const virtio_blk = drivers.virtio_blk;

const SpinLock = @import("arch").spinlock.SpinLock;
const kprint = @import("common").utils.kprint;

pub const Options = struct {
    cache_entries: usize = 8,
    // write_back: bool = false,
};

// Simple block cache entry
// It's Round-Robin.
// The hit only updates the data and
// will not change the position of the next replacement.
const Cache= struct {
    entries: []Entry,
    data: []u8,
    block_size: usize,
    next: usize = 0,
    const Entry = struct {
        lba: u64 = 0,       // Logic Block Address
        data: []u8,
        valid: bool = false,
        // dirty: bool = false, // implement for write-back
    };

    pub fn init(alloc: std.mem.Allocator, block_size: usize, count: usize) !Cache {
        std.debug.assert(count > 0);
        std.debug.assert(block_size > 0);

        const entries = try alloc.alloc(Entry, count);
        errdefer alloc.free(entries);

        const data = try alloc.alloc(u8, block_size * count);
        errdefer alloc.free(data);

        for (entries, 0..) |*entry, i| {
            entry.* = .{
                .data = data[i * block_size ..][0..block_size],
            };
        }

        return .{
            .entries = entries,
            .data = data,
            .block_size = block_size,
        };
    }

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        alloc.free(self.entries);
        self.* = undefined;
    }

    pub fn find(self: *Cache, lba: u64) ?*Entry {
        for (self.entries) |*entry| {
            if (entry.valid and entry.lba == lba) return entry;
        }
        return null;
    }

    pub fn insert(self: *Cache, lba: u64, data: []const u8) void {
        std.debug.assert(data.len == self.block_size);

        if (self.find(lba)) |entry| {
            @memcpy(entry.data, data);
            return;
        }
        const entry = &self.entries[self.next];
        self.next = (self.next + 1) % self.entries.len;

        entry.lba = lba;
        @memcpy(entry.data, data);
        entry.valid = true;
    }

    pub fn invalidate(self: *Cache, lba: u64) void {
        if (self.find(lba)) |entry| entry.valid = false;
    }

    pub fn invalidateAll(self: *Cache) void {
        for (self.entries) |*entry| entry.valid = false;
        self.next = 0;
    }
};

pub const BlockDevice = struct {
    dev: *const device.Device,
    ops: device.BlockOps,
    cache: ?Cache,
    lock: SpinLock,

    fn rawRead(self: *BlockDevice, lba: u64, buf: []u8) !void {
        const n = try self.ops.read(self.dev.ctx, lba, buf);
        if (n != self.ops.block_size) return error.PartialRead;
    }

    fn rawWrite(self: *BlockDevice, lba: u64, buf: []const u8) !void {
        const n = try self.ops.write(self.dev.ctx, lba, buf);
        if (n != self.ops.block_size) return error.PartialWrite;
    }

    pub fn read(self: *BlockDevice, lba: u64, buf: []u8) !void {
        if (lba >= self.ops.block_count) return error.InvalidBlock;
        if (buf.len != self.ops.block_size) return error.InvalidBufferSize;

        self.lock.acquire();
        defer self.lock.release();

        if (self.cache) |*cache| {
            if (cache.find(lba)) |entry| {
                @memcpy(buf, entry.data);
                return;
            }
        }
        try rawRead(self, lba, buf);
        if (self.cache) |*cache| cache.insert(lba, buf);
    }

    pub fn write(self: *BlockDevice, lba: u64, buf: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (lba >= self.ops.block_count) return error.InvalidBlock;
        if (buf.len != self.ops.block_size) return error.InvalidBufferSize;

        try rawWrite(self, lba, buf);
        if (self.cache) |*cache| cache.insert(lba, buf);
    }

    pub fn sync(self: *BlockDevice) !void {
        self.lock.acquire;
        defer self.lock.release();

        if (self.ops.flush) |flush| try flush(self.dev.ctx);
    }

    pub fn close(self: *BlockDevice, alloc: std.mem.Allocator) void {
        if (self.cache) |*cache| cache.deinit(alloc);
        alloc.destroy(self);
    }
};

pub fn open(dev: *const device.Device, opts: Options, alloc: std.mem.Allocator) !*BlockDevice {
    const ops = switch (dev.ops) {
        .Block => |block_ops| block_ops,
        .Char => return error.NotABlockDevice,
    };

    const handle = try alloc.create(BlockDevice);
    errdefer alloc.destroy(handle);

    handle.* = .{ 
        .dev = dev,
        .ops = ops,
        .lock = SpinLock.init("block"),
        .cache = if (opts.cache_entries == 0)
            null
        else try Cache.init(alloc, ops.block_size, opts.cache_entries),
    };

    return handle;
}
