const std = @import("std");

const device = @import("device");
const block = @import("block");

const vfs = @import("vfs.zig");

const kprint = @import("common").utils.kprint;

// ============================================================================
// On-Disk Structures (merged from zfs_disk.zig)
// ============================================================================

// Block size (4KB)
pub const ZFS_BLOCK_SIZE: usize = 4096;

// Magic number
pub const ZFS_MAGIC: u64 = 0x5A495353554D4F21; // "ZIGSUM!"

// Version
pub const ZFS_VERSION: u32 = 2;

// Maximum file name length (24 bytes to make DirEntry exactly 32 bytes)
pub const MAX_NAME_LEN: usize = 24;

// Maximum direct blocks per inode
pub const DIRECT_BLOCKS: usize = 12;

// Use for `reserved` member
pub const INDIRECT_BLOCK = 0;
pub const DOUBLE_INDIRECT_BLOCK = 1;
pub const TRIPLE_INDIRECT_BLOCK = 2;

const PTRS_PER_BLOCK = ZFS_BLOCK_SIZE / @sizeOf(u32); // 1024
const SINGLE_INDIRECT_CAP = DIRECT_BLOCKS + PTRS_PER_BLOCK; // 12 + 1024

// Maximum file size: 12 * 4KB + (4096 / 4) * 4K = 48KB + 4MB
pub const MAX_FILE_SIZE: usize = SINGLE_INDIRECT_CAP * ZFS_BLOCK_SIZE;

// Filesystem superblock (on disk, at block 1)
pub const SuperBlock = extern struct {
    magic: u64,
    version: u32,
    block_size: u32,
    block_count: u32,
    inode_count: u32,
    free_blocks: u32,
    free_inodes: u32,
    root_inode: u32,
    creation_time: u64,
    block_bitmap_start: u32,
    inode_bitmap_start: u32,
    inode_table_start: u32,
    data_start: u32,
    reserved: [448]u8, // Pad to 512 bytes

    comptime {
        std.debug.assert(@sizeOf(SuperBlock) == 512);
    }

    pub fn init(block_count: u32, inode_count: u32) SuperBlock {
        return SuperBlock{
            .magic = ZFS_MAGIC,
            .version = ZFS_VERSION,
            .block_size = ZFS_BLOCK_SIZE,
            .block_count = block_count,
            .inode_count = inode_count,
            .free_blocks = block_count - 22, // Reserve first 22 blocks
            .free_inodes = inode_count - 1, // Root inode already allocated
            .root_inode = 0,
            .creation_time = 0,
            .block_bitmap_start = 2,
            .inode_bitmap_start = 3,
            .inode_table_start = 4,
            .data_start = 22,
            .reserved = std.mem.zeroes([448]u8),
        };
    }

    pub fn isValid(self: *const SuperBlock) bool {
        return self.magic == ZFS_MAGIC and self.version == ZFS_VERSION;
    }
};

// File types
pub const FileType = enum(u8) {
    Free = 0,
    Regular = 1,
    Directory = 2,
};

// Inode structure (on disk, 128 bytes)
pub const Inode = extern struct {
    id: u32,
    type_: u8,
    mode: u16,
    size: u32,
    uid: u16,
    gid: u16,
    nlink: u16,
    created: u64,
    modified: u64,
    blocks: [DIRECT_BLOCKS]u32, // contain 12 * 4096(48K) bytes data in an inode
    single_indirect: u32, // pointer to block data -> blocks[lb]
    double_indirect: u32, // pointer to block lb -> pointer[lb - 12]
    triple_indirect: u32,
    reserved: [7]u32,

    pub fn init(id: u32, type_val: FileType, mode: u16) Inode {
        return Inode{
            .id = id,
            .type_ = @backingInt(type_val),
            .mode = mode,
            .size = 0,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
            .created = 0,
            .modified = 0,
            .blocks = std.mem.zeroes([DIRECT_BLOCKS]u32),
            .single_indirect = 0,
            .double_indirect = 0,
            .triple_indirect = 0,
            .reserved = std.mem.zeroes([7]u32),
        };
    }

    pub fn getFileType(self: *const Inode) FileType {
        return @fromBackingInt(@intCast(self.type_));
    }

    pub fn isFree(self: *const Inode) bool {
        return self.type_ == @backingInt(FileType.Free);
    }

    pub fn isRegular(self: *const Inode) bool {
        return self.type_ == @backingInt(FileType.Regular);
    }

    pub fn isDirectory(self: *const Inode) bool {
        return self.type_ == @backingInt(FileType.Directory);
    }
};

// Directory entry (on disk, 32 bytes)
pub const DirEntry = extern struct {
    name: [MAX_NAME_LEN]u8,
    inode: u32,
    _padding: u32,

    pub fn init(name: []const u8, inode_num: u32) DirEntry {
        var entry = DirEntry{
            .name = std.mem.zeroes([MAX_NAME_LEN]u8),
            .inode = inode_num,
            ._padding = 0,
        };
        const len = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name[0..len], name[0..len]);
        return entry;
    }

    pub fn getName(self: *const DirEntry) []const u8 {
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }
        return self.name[0..MAX_NAME_LEN];
    }

    pub fn isFree(self: *const DirEntry) bool {
        return self.inode == 0;
    }
};

// Maximum entries per directory block
pub const ENTRIES_PER_BLOCK = ZFS_BLOCK_SIZE / @sizeOf(DirEntry);

// In-memory filesystem state
pub const FileSystemLayout = struct {
    super: SuperBlock,
    block_count: u32,
    inode_count: u32,

    pub fn blockBitmapStart(_: *const FileSystemLayout) u32 {
        return 2;
    }

    pub fn inodeBitmapStart(self: *const FileSystemLayout) u32 {
        const blocks_needed = (self.block_count + 7) / 8 / ZFS_BLOCK_SIZE;
        return 2 + @max(blocks_needed, 1);
    }

    pub fn inodeTableStart(self: *const FileSystemLayout) u32 {
        const inode_blocks_needed = (self.inode_count + 7) / 8 / ZFS_BLOCK_SIZE;
        return self.inodeBitmapStart() + @max(inode_blocks_needed, 1);
    }

    pub fn dataStart(self: *const FileSystemLayout) u32 {
        const inode_table_blocks = (self.inode_count * @sizeOf(Inode) + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
        return self.inodeTableStart() + @max(inode_table_blocks, 1);
    }
};

// Calculate filesystem layout for given disk size
pub fn calculateLayout(disk_size_bytes: u64) FileSystemLayout {
    const block_count: u32 = @truncate(disk_size_bytes / ZFS_BLOCK_SIZE);
    const inode_count: u32 = @truncate((disk_size_bytes / (16 * 1024)) + 1);

    return FileSystemLayout{
        .super = SuperBlock.init(block_count, inode_count),
        .block_count = block_count,
        .inode_count = inode_count,
    };
}

// Test size assertions
comptime {
    std.debug.assert(@sizeOf(SuperBlock) == 512);
    std.debug.assert(@sizeOf(Inode) == 128);
    std.debug.assert(@sizeOf(DirEntry) == 32);
}

// ============================================================================
// Runtime State and Operations
// ============================================================================

// In-memory ZFS state
const ZFSState = struct {
    allocator: std.mem.Allocator,
    blk: *block.BlockDevice,
    super: SuperBlock,
    block_count: u32,
    inode_count: u32,
    block_bitmap: []u8,
    inode_bitmap: []u8,
    mounted: bool,
};

var zfs_state: ?ZFSState = null;

const zero_block: [ZFS_BLOCK_SIZE]u8 = @splat(0);

// ZFS inode data (in-memory extension of on-disk inode)
const ZFSInodeData = struct {
    disk_inode: Inode,
    inode_num: u32,
};

fn getBlockData(inode: *const Inode, logical_block: usize) !?u32 {
    if (inode.double_indirect != 0 or inode.triple_indirect != 0) {
        return error.UnsupportedIndirectBlock;
    }

    if (logical_block < DIRECT_BLOCKS) {
        return inode.blocks[logical_block];
    }
    const single_idx = logical_block - DIRECT_BLOCKS;
    if (single_idx < PTRS_PER_BLOCK) {
        const indirect = inode.single_indirect;
        if (indirect == 0) return null;

        var entries: [PTRS_PER_BLOCK]u32 = undefined;
        try zfs_state.?.blk.read(indirect, std.mem.asBytes(&entries));
        return entries[single_idx];
    }

    return error.FileTooLarge;
}

fn allocZeroedBlock() !u32 {
    const blk_num = try allocBlock();
    errdefer freeBlock(blk_num);

    try zfs_state.?.blk.write(blk_num, &zero_block);

    return blk_num;
}

fn getOrAllocDataBlock(inode: *Inode, logical_block: usize) !u32 {
    if (inode.double_indirect != 0 or inode.triple_indirect != 0) {
        return error.UnsupportedIndirectBlock;
    }

    if (logical_block < DIRECT_BLOCKS) {
        if (inode.blocks[logical_block] == 0) {
            inode.blocks[logical_block] = try allocZeroedBlock();
        }
        return inode.blocks[logical_block];
    }

    const single_idx = logical_block - DIRECT_BLOCKS;
    if (single_idx < PTRS_PER_BLOCK) {
        const needs_indirect_block = inode.single_indirect == 0;
        const indirect_block = if (needs_indirect_block)
            try allocZeroedBlock()
        else
            inode.single_indirect;
        errdefer if (needs_indirect_block) freeBlock(indirect_block);

        var entries = std.mem.zeroes([PTRS_PER_BLOCK]u32);
        if (!needs_indirect_block) {
            try zfs_state.?.blk.read(indirect_block, std.mem.asBytes(&entries));
        }

        if (entries[single_idx] == 0) {
            const data_block = try allocZeroedBlock();
            errdefer freeBlock(data_block);

            entries[single_idx] = data_block;
            try zfs_state.?.blk.write(indirect_block, std.mem.asBytes(&entries));
        }

        if (needs_indirect_block) inode.single_indirect = indirect_block;
        return entries[single_idx];
    }

    return error.FileTooLarge;
}

fn freeAllBlocks(inode: *const Inode) !void {
    if (inode.double_indirect != 0 or inode.triple_indirect != 0) {
        return error.UnsupportedIndirectBlock;
    }

    var entries = std.mem.zeroes([PTRS_PER_BLOCK]u32);
    if (inode.single_indirect != 0) {
        try zfs_state.?.blk.read(inode.single_indirect, std.mem.asBytes(&entries));
    }

    for (inode.blocks) |blk| {
        if (blk != 0) freeBlock(blk);
    }

    for (entries) |blk| {
        if (blk != 0) freeBlock(blk);
    }
    if (inode.single_indirect != 0) {
        freeBlock(inode.single_indirect);
    }
}

fn directoryBlockCount(inode: *const Inode) usize {
    const size: usize = inode.size;
    const block_count = (size + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
    return @min(block_count, SINGLE_INDIRECT_CAP);
}

// Calculate block number for inode
fn inodeToBlock(inode_num: u32) u32 {
    const inode_offset = inode_num * @sizeOf(Inode);
    const block_offset = inode_offset / ZFS_BLOCK_SIZE;
    return zfs_state.?.super.inode_table_start + @as(u32, @truncate(block_offset));
}

// Calculate offset within block for inode
fn inodeToOffset(inode_num: u32) usize {
    const inode_offset = inode_num * @sizeOf(Inode);
    return inode_offset % ZFS_BLOCK_SIZE;
}

// Read inode from disk
fn readInodeFromDisk(inode_num: u32) !Inode {
    if (inode_num >= zfs_state.?.inode_count) return error.InvalidInode;

    const blk_num = inodeToBlock(inode_num);
    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;

    try zfs_state.?.blk.read(blk_num, &buffer);

    const offset = inodeToOffset(inode_num);
    const inode_ptr = @as(*const Inode, @ptrCast(@alignCast(&buffer[offset])));

    return inode_ptr.*;
}

// Write inode to disk
fn writeInodeToDisk(inode: *const Inode) !void {
    if (inode.id >= zfs_state.?.inode_count) return error.InvalidInode;

    const blk_num = inodeToBlock(inode.id);
    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;

    try zfs_state.?.blk.read(blk_num, &buffer);

    const offset = inodeToOffset(inode.id);
    const inode_ptr = @as(*Inode, @ptrCast(@alignCast(&buffer[offset])));
    inode_ptr.* = inode.*;

    try zfs_state.?.blk.write(blk_num, &buffer);
}

// Allocate a new block
fn allocBlock() !u32 {
    const state = &zfs_state.?;
    for (state.super.data_start..state.block_count) |blk_num| {
        const byte_idx = blk_num / 8;
        const bit_idx = @as(u3, @truncate(blk_num % 8));
        if (state.block_bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
            state.block_bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
            state.super.free_blocks -= 1;
            return @truncate(blk_num);
        }
    }
    return error.NoFreeBlocks;
}

// Free a block
fn freeBlock(blk_num: u32) void {
    const state = &zfs_state.?;
    if (blk_num < state.super.data_start or blk_num >= state.block_count) return;

    const byte_idx = blk_num / 8;
    const bit_idx = @as(u3, @truncate(blk_num % 8));
    const mask = @as(u8, 1) << bit_idx;

    if (state.block_bitmap[byte_idx] & mask == 0) return;
    state.block_bitmap[byte_idx] &= ~mask;
    state.super.free_blocks += 1;
}

// Allocate a new inode
fn allocInode(type_val: FileType, mode: u16) !u32 {
    const state = &zfs_state.?;
    for (0..state.inode_count) |i| {
        if (i == 0) continue;
        const byte_idx = i / 8;
        const bit_idx = @as(u3, @truncate(i % 8));
        if (state.inode_bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
            state.inode_bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
            state.super.free_inodes -= 1;

            var inode = Inode.init(@truncate(i), type_val, mode);
            try writeInodeToDisk(&inode);

            return @truncate(i);
        }
    }
    return error.NoFreeInodes;
}

// Free an inode
fn freeInode(inode_num: u32) void {
    const state = &zfs_state.?;
    if (inode_num == 0 or inode_num >= state.inode_count) return;

    const byte_idx = inode_num / 8;
    const bit_idx = @as(u3, @truncate(inode_num % 8));

    state.inode_bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    state.super.free_inodes += 1;
}

// Write superblock to disk
fn writeSuperBlock() !void {
    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(SuperBlock)], std.mem.asBytes(&zfs_state.?.super));
    try zfs_state.?.blk.write(1, &buffer);
}

// Write block bitmap to disk
fn writeBlockBitmap() !void {
    const state = &zfs_state.?;
    const blocks_needed = (state.block_bitmap.len + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
    for (0..blocks_needed) |i| {
        const offset = i * ZFS_BLOCK_SIZE;
        const remaining = state.block_bitmap.len - offset;
        const len = @min(ZFS_BLOCK_SIZE, remaining);
        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        @memset(&buffer, 0);
        @memcpy(buffer[0..len], state.block_bitmap[offset..][0..len]);
        try zfs_state.?.blk.write(state.super.block_bitmap_start + @as(u32, @truncate(i)), &buffer);
    }
}

// Write inode bitmap to disk
fn writeInodeBitmap() !void {
    const state = &zfs_state.?;
    const blocks_needed = (state.inode_bitmap.len + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
    for (0..blocks_needed) |i| {
        const offset = i * ZFS_BLOCK_SIZE;
        const remaining = state.inode_bitmap.len - offset;
        const len = @min(ZFS_BLOCK_SIZE, remaining);
        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        @memset(&buffer, 0);
        @memcpy(buffer[0..len], state.inode_bitmap[offset..][0..len]);
        try zfs_state.?.blk.write(state.super.inode_bitmap_start + @as(u32, @truncate(i)), &buffer);
    }
}

// VFS operations

fn zfs_lookup(parent: *vfs.Inode, name: []const u8) !?*vfs.Inode {
    const data = @as(*ZFSInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));
    var disk_inode = data.disk_inode;

    if (disk_inode.getFileType() != .Directory) return error.NotADirectory;

    for (0..directoryBlockCount(&disk_inode)) |logical_block| {
        const maybe_blk = try getBlockData(&disk_inode, logical_block);
        const blk_num = maybe_blk orelse continue;
        if (blk_num == 0) continue;

        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try zfs_state.?.blk.read(blk_num, &buffer);

        var offset: usize = 0;
        while (offset < ZFS_BLOCK_SIZE) : (offset += @sizeOf(DirEntry)) {
            const entry = @as(*const DirEntry, @ptrCast(@alignCast(&buffer[offset])));
            if (entry.isFree()) continue;

            const entry_name = entry.getName();
            if (std.mem.eql(u8, entry_name, name)) {
                const child_disk_inode = try readInodeFromDisk(entry.inode);
                return createVfsInode(&child_disk_inode, parent.fs, entry.inode);
            }
        }
    }

    return null;
}

fn zfs_create(parent: *vfs.Inode, name: []const u8, mode: u32) !*vfs.Inode {
    const inode_num = try allocInode(.Regular, @truncate(mode));
    var disk_inode = try readInodeFromDisk(inode_num);

    try addDirEntry(parent, name, inode_num);

    return createVfsInode(&disk_inode, parent.fs, inode_num);
}

fn zfs_mkdir(parent: *vfs.Inode, name: []const u8, mode: u32) !*vfs.Inode {
    const mode16: u16 = @truncate(mode);
    const inode_num = try allocInode(.Directory, mode16 | 0o040000);
    var disk_inode = try readInodeFromDisk(inode_num);

    const first_block = try allocBlock();
    disk_inode.blocks[0] = first_block;
    disk_inode.size = ZFS_BLOCK_SIZE;
    try writeInodeToDisk(&disk_inode);

    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    @memset(&buffer, 0);

    const entries = @as([*]DirEntry, @ptrCast(@alignCast(&buffer[0])));
    entries[0] = DirEntry.init(".", inode_num);
    entries[1] = DirEntry.init("..", @as(*ZFSInodeData, @ptrCast(@alignCast(parent.fs_specific.?))).inode_num);

    try zfs_state.?.blk.write(first_block, &buffer);
    try addDirEntry(parent, name, inode_num);

    return createVfsInode(&disk_inode, parent.fs, inode_num);
}

fn zfs_unlink(parent: *vfs.Inode, name: []const u8) !void {
    const parent_data = @as(*ZFSInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));
    var disk_inode = parent_data.disk_inode;

    if (disk_inode.getFileType() != .Directory) return error.NotADirectory;

    var found = false;
    var entry_inode: u32 = 0;

    for (0..directoryBlockCount(&disk_inode)) |logical_block| {
        const maybe_blk = try getBlockData(&disk_inode, logical_block);
        const blk_num = maybe_blk orelse continue;
        if (blk_num == 0) continue;

        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try zfs_state.?.blk.read(blk_num, &buffer);

        var offset: usize = 0;
        while (offset < ZFS_BLOCK_SIZE) : (offset += @sizeOf(DirEntry)) {
            const entry = @as(*DirEntry, @ptrCast(@alignCast(&buffer[offset])));
            if (entry.isFree()) continue;

            const entry_name = entry.getName();
            if (std.mem.eql(u8, entry_name, name)) {
                entry_inode = entry.inode;
                entry.inode = 0;
                try zfs_state.?.blk.write(blk_num, &buffer);
                found = true;
                break;
            }
        }
        if (found) break;
    }

    if (!found) return error.FileNotFound;

    const child_inode = try readInodeFromDisk(entry_inode);
    try freeAllBlocks(&child_inode);
    freeInode(entry_inode);

    try writeBlockBitmap();
    try writeInodeBitmap();
}

fn zfs_read(inode: *vfs.Inode, buffer: []u8, offset: usize) !usize {
    const data = @as(*ZFSInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));
    const disk_inode = data.disk_inode;

    if (disk_inode.getFileType() != .Regular) return error.IsADirectory;
    if (offset >= disk_inode.size) return 0;

    const to_read = @min(buffer.len, disk_inode.size - offset);
    var bytes_read: usize = 0;
    var current_offset = offset;

    while (bytes_read < to_read) {
        const block_idx = current_offset / ZFS_BLOCK_SIZE;
        const maybe_blk = try getBlockData(&disk_inode, block_idx);

        const block_offset = current_offset % ZFS_BLOCK_SIZE;
        const bytes_in_block = @min(ZFS_BLOCK_SIZE - block_offset, to_read - bytes_read);

        if (maybe_blk) |blk_num| {
            var block_buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
            try zfs_state.?.blk.read(blk_num, &block_buffer);

            @memcpy(buffer[bytes_read..][0..bytes_in_block], block_buffer[block_offset..][0..bytes_in_block]);
        } else {
            @memset(buffer[bytes_read..][0..bytes_in_block], 0);
        }

        bytes_read += bytes_in_block;
        current_offset += bytes_in_block;
    }

    return bytes_read;
}

fn zfs_write(inode: *vfs.Inode, data_buffer: []const u8, offset: usize) !usize {
    const inode_data = @as(*ZFSInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));
    var disk_inode = inode_data.disk_inode;

    if (disk_inode.getFileType() != .Regular) return error.IsADirectory;

    const new_size = offset + data_buffer.len;
    if (new_size > MAX_FILE_SIZE) return error.FileTooLarge;

    var bytes_written: usize = 0;
    var current_offset = offset;

    while (bytes_written < data_buffer.len) {
        const block_idx = current_offset / ZFS_BLOCK_SIZE;
        const blk_num = try getOrAllocDataBlock(&disk_inode, block_idx);

        const block_offset = current_offset % ZFS_BLOCK_SIZE;
        const bytes_to_write = @min(ZFS_BLOCK_SIZE - block_offset, data_buffer.len - bytes_written);

        var block_buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try zfs_state.?.blk.read(blk_num, &block_buffer);

        @memcpy(block_buffer[block_offset..][0..bytes_to_write], data_buffer[bytes_written..][0..bytes_to_write]);

        try zfs_state.?.blk.write(blk_num, &block_buffer);

        bytes_written += bytes_to_write;
        current_offset += bytes_to_write;
    }

    if (new_size > disk_inode.size) {
        disk_inode.size = @truncate(new_size);
    }
    try writeInodeToDisk(&disk_inode);
    inode_data.disk_inode = disk_inode;
    inode.size = disk_inode.size;

    try writeBlockBitmap();
    try writeInodeBitmap();

    return bytes_written;
}

fn zfs_readdir(inode: *vfs.Inode, index: usize) !?vfs.DirEntry {
    const data = @as(*ZFSInodeData, @ptrCast(@alignCast(inode.fs_specific.?)));
    const disk_inode = data.disk_inode;

    if (disk_inode.getFileType() != .Directory) return error.NotADirectory;

    var current_idx: usize = 0;

    for (0..directoryBlockCount(&disk_inode)) |logical_block| {
        const maybe_blk = try getBlockData(&disk_inode, logical_block);
        const blk_num = maybe_blk orelse continue;
        if (blk_num == 0) continue;

        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try zfs_state.?.blk.read(blk_num, &buffer);

        var offset: usize = 0;
        while (offset < ZFS_BLOCK_SIZE) : (offset += @sizeOf(DirEntry)) {
            const entry = @as(*const DirEntry, @ptrCast(@alignCast(&buffer[offset])));
            if (entry.isFree()) continue;

            if (current_idx == index) {
                const entry_inode = try readInodeFromDisk(entry.inode);
                return vfs.DirEntry{
                    .name = entry.getName(),
                    .inode_id = entry.inode,
                    .file_type = if (entry_inode.isDirectory()) .Directory else .Regular,
                };
            }
            current_idx += 1;
        }
    }

    return null;
}

// Helper function: add directory entry
fn addDirEntry(parent: *vfs.Inode, name: []const u8, inode_num: u32) !void {
    const parent_data = @as(*ZFSInodeData, @ptrCast(@alignCast(parent.fs_specific.?)));
    var disk_inode = parent_data.disk_inode;

    if (disk_inode.getFileType() != .Directory) return error.NotADirectory;

    const existing_blocks = directoryBlockCount(&disk_inode);
    var block_idx: usize = 0;
    while (block_idx < existing_blocks) : (block_idx += 1) {
        const maybe_blk = try getBlockData(&disk_inode, block_idx);
        const blk_num = if (maybe_blk) |existing_blk|
            if (existing_blk != 0) existing_blk else try getOrAllocDataBlock(&disk_inode, block_idx)
        else
            try getOrAllocDataBlock(&disk_inode, block_idx);

        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try zfs_state.?.blk.read(blk_num, &buffer);

        var offset: usize = 0;
        while (offset < ZFS_BLOCK_SIZE) : (offset += @sizeOf(DirEntry)) {
            const entry = @as(*DirEntry, @ptrCast(@alignCast(&buffer[offset])));
            if (entry.isFree()) {
                entry.* = DirEntry.init(name, inode_num);
                try zfs_state.?.blk.write(blk_num, &buffer);
                try writeInodeToDisk(&disk_inode);
                parent_data.disk_inode = disk_inode;
                parent.size = disk_inode.size;
                try writeBlockBitmap();
                return;
            }
        }
    }

    if (block_idx >= SINGLE_INDIRECT_CAP) return error.NoSpaceLeft;

    const blk_num = try getOrAllocDataBlock(&disk_inode, block_idx);
    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    try zfs_state.?.blk.read(blk_num, &buffer);

    const entry = @as(*DirEntry, @ptrCast(@alignCast(&buffer[0])));
    entry.* = DirEntry.init(name, inode_num);

    disk_inode.size = @intCast((block_idx + 1) * ZFS_BLOCK_SIZE);

    try zfs_state.?.blk.write(blk_num, &buffer);
    try writeInodeToDisk(&disk_inode);
    parent_data.disk_inode = disk_inode;
    parent.size = disk_inode.size;

    try writeBlockBitmap();
}

// Helper function: create VFS inode from ZFS inode
fn createVfsInode(disk_inode: *const Inode, fs: *vfs.FileSystem, inode_num: u32) !*vfs.Inode {
    const allocator = zfs_state.?.allocator;

    const inode = try allocator.create(vfs.Inode);
    errdefer allocator.destroy(inode);

    const data = try allocator.create(ZFSInodeData);
    errdefer allocator.destroy(data);

    data.* = ZFSInodeData{
        .disk_inode = disk_inode.*,
        .inode_num = inode_num,
    };

    const file_type = if (disk_inode.isDirectory()) vfs.FileType.Directory else vfs.FileType.Regular;

    inode.* = vfs.Inode.init(
        inode_num,
        file_type,
        disk_inode.size,
        disk_inode.mode,
        fs,
    );
    inode.fs_specific = data;

    return inode;
}

// Mount ZFS as root filesystem
pub fn mountZFSRoot(allocator: std.mem.Allocator, blk: *block.BlockDevice) ?*vfs.FileSystem {
    const zfs_fs = mountZFS(allocator, blk) catch |err| {
        kprint("Failed to mount ZFS: {}\n", .{err});
        return null;
    };

    kprint("ZFS filesystem mounted successfully\n", .{});
    return zfs_fs;
}

// Populate ZFS root with essential directories
pub fn populateZFSRoot() void {
    const v = vfs.get_vfs();
    v.mkdir("/bin") catch |err| {
        if (err != vfs.VfsError.AlreadyExists) {
            kprint("Warning: Failed to create /bin: {}\n", .{err});
        }
    };
    v.mkdir("/dev") catch |err| {
        if (err != vfs.VfsError.AlreadyExists) {
            kprint("Warning: Failed to create /bin: {}\n", .{err});
        }
    };
    v.mkdir("/tmp") catch |err| {
        if (err != vfs.VfsError.AlreadyExists) {
            kprint("Warning: Failed to create /bin: {}\n", .{err});
        }
    };
}

// Mount ZFS filesystem
pub fn mountZFS(allocator: std.mem.Allocator, blk: *block.BlockDevice) !*vfs.FileSystem {
    kprint("Mounting ZFS filesystem...\n", .{});
    if (blk.ops.block_size != ZFS_BLOCK_SIZE) return error.UnsupportedBlockSize;

    var super_buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    try blk.read(1, &super_buffer);

    var super = @as(*const SuperBlock, @ptrCast(@alignCast(&super_buffer[0]))).*;

    if (!super.isValid()) {
        kprint("ZFS: Invalid superblock, not a ZFS filesystem\n", .{});
        return error.InvalidFilesystem;
    }

    kprint("ZFS: Magic valid, version={}, {} blocks, {} inodes\n", .{
        super.version, super.block_count, super.inode_count,
    });

    const block_bitmap_size = (super.block_count + 7) / 8;
    const inode_bitmap_size = (super.inode_count + 7) / 8;

    const block_bitmap = try allocator.alloc(u8, block_bitmap_size);
    const inode_bitmap = try allocator.alloc(u8, inode_bitmap_size);

    const block_bitmap_blocks = (block_bitmap_size + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
    for (0..block_bitmap_blocks) |i| {
        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try blk.read(super.block_bitmap_start + @as(u32, @truncate(i)), &buffer);
        const offset = i * ZFS_BLOCK_SIZE;
        const remaining = block_bitmap_size - offset;
        const len = @min(ZFS_BLOCK_SIZE, remaining);
        @memcpy(block_bitmap[offset..][0..len], buffer[0..len]);
    }

    const inode_bitmap_blocks = (inode_bitmap_size + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE;
    for (0..inode_bitmap_blocks) |i| {
        var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
        try blk.read(super.inode_bitmap_start + @as(u32, @truncate(i)), &buffer);
        const offset = i * ZFS_BLOCK_SIZE;
        const remaining = inode_bitmap_size - offset;
        const len = @min(ZFS_BLOCK_SIZE, remaining);
        @memcpy(inode_bitmap[offset..][0..len], buffer[0..len]);
    }

    zfs_state = ZFSState{
        .allocator = allocator,
        .blk = blk,
        .super = super,
        .block_count = super.block_count,
        .inode_count = super.inode_count,
        .block_bitmap = block_bitmap,
        .inode_bitmap = inode_bitmap,
        .mounted = true,
    };

    const fs = try allocator.create(vfs.FileSystem);
    errdefer allocator.destroy(fs);

    const root_disk_inode = try readInodeFromDisk(0);
    const root_inode = try createVfsInode(&root_disk_inode, fs, 0);

    fs.* = .{
        .name = "zfs",
        .ops = .{
            .lookup = zfs_lookup,
            .create = zfs_create,
            .mkdir = zfs_mkdir,
            .unlink = zfs_unlink,
            .read = zfs_read,
            .write = zfs_write,
            .readdir = zfs_readdir,
        },
        .root_inode = root_inode,
        .superblock = &zfs_state.?.super,
    };

    kprint("ZFS mounted successfully at /persist\n", .{});
    return fs;
}

// Format a new ZFS filesystem
pub fn formatZFS(block_count: u32, inode_count: u32) !void {
    kprint("Formatting ZFS filesystem: {} blocks, {} inodes\n", .{ block_count, inode_count });

    var super = SuperBlock.init(block_count, inode_count);
    super.inode_table_start = 2;
    super.inode_bitmap_start = super.inode_table_start + @max((inode_count * @sizeOf(Inode) + ZFS_BLOCK_SIZE - 1) / ZFS_BLOCK_SIZE, 1);
    super.block_bitmap_start = super.inode_bitmap_start + @max((inode_count + 7) / 8 / ZFS_BLOCK_SIZE, 1);
    super.data_start = super.block_bitmap_start + @max((block_count + 7) / 8 / ZFS_BLOCK_SIZE, 1);

    var buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    @memset(&buffer, 0);
    @memcpy(buffer[0..@sizeOf(SuperBlock)], std.mem.asBytes(&super));
    try zfs_state.?.blk.write(1, &buffer);

    var inode_bitmap = std.mem.zeroes([ZFS_BLOCK_SIZE]u8);
    inode_bitmap[0] = 0x01;
    try zfs_state.?.blk.write(super.inode_bitmap_start, &inode_bitmap[0..ZFS_BLOCK_SIZE]);

    var block_bitmap = std.mem.zeroes([ZFS_BLOCK_SIZE]u8);
    const meta_blocks = super.data_start;
    for (0..meta_blocks) |i| {
        block_bitmap[i / 8] |= @as(u8, 1) << @as(u3, @truncate(i % 8));
    }
    try zfs_state.?.blk.write(super.block_bitmap_start, &block_bitmap[0..ZFS_BLOCK_SIZE]);

    var root_inode = Inode.init(0, .Directory, 0o755 | 0o040000);
    const first_block = super.data_start;
    root_inode.blocks[0] = first_block;
    root_inode.size = ZFS_BLOCK_SIZE;

    const root_block = super.inode_table_start;
    var inode_buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    @memset(&inode_buffer, 0);
    @memcpy(inode_buffer[0..@sizeOf(Inode)], std.mem.asBytes(&root_inode));
    try zfs_state.?.blk.write(root_block, &inode_buffer);

    var dir_buffer: [ZFS_BLOCK_SIZE]u8 = undefined;
    @memset(&dir_buffer, 0);
    const entries = @as([*]DirEntry, @ptrCast(@alignCast(&dir_buffer[0])));
    entries[0] = DirEntry.init(".", 0);
    entries[1] = DirEntry.init("..", 0);
    try zfs_state.?.blk.write(first_block, &dir_buffer);

    kprint("ZFS format complete\n", .{});
}
