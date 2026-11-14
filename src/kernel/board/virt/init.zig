const std = @import("std");

const device = @import("device");
const block = @import("block");
const virtio = @import("drivers").virtio;
const virtio_blk = @import("drivers").virtio_blk;

const kprint = @import("common").utils.kprint;

// Initialize VirtIO block device and block layer
pub fn probeBlock(alloc: std.mem.Allocator) !?*block.BlockDevice {
    kprint("Scanning for VirtIO block device...\n", .{});

    const mmio = virtio.scanForDevice(.Block) orelse return null;
    if (!virtio.initVirtIO(mmio, .Block)) return error.VirtioInit;
    if (!try virtio_blk.initVirtioBlk(alloc, mmio)) return error.BlkInit;

    kprint("VirtIO block device initialized\n", .{});

    const dev = try alloc.create(device.Device);
    dev.* = .{
        .num = .{ .major = 8, .minor = 0 },
        .dev_type = .Block,
        .name = "vda",
        .ctx = @ptrCast(virtio_blk.instance()),
        .ops = .{ .Block = .{
            .read = &virtio_blk.blkRead,
            .write = &virtio_blk.blkWrite,
            .block_size = virtio_blk.LOGICAL_BLOCK_SIZE,
            .block_count = virtio_blk.getCapacity() / virtio_blk.LOGICAL_BLOCK_SIZE,
        } },
    };

    try device.register(dev);

    return try block.open(dev, . { .cache_entries = 8 }, alloc);
}
