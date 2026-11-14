const std = @import("std");
const virtio = @import("virtio.zig");
const plic = @import("plic.zig");

const riscv = @import("arch").riscv;
const kprint = @import("common").utils.kprint;

// Physical to virtual address conversion
fn virtToPhys(virt_addr: usize) usize {
    return virt_addr; // Identity mapping in QEMU
}

// Queue size - must be power of 2
pub const QUEUE_SIZE: u16 = 16;

const SECTOR_SIZE: u64 = 512;
pub const LOGICAL_BLOCK_SIZE: u64 = 4096;

// VirtQueue structure (simplified for single queue)
pub const VirtQueue = struct {
    desc: [*]volatile virtio.Desc,
    avail: [*]volatile virtio.Avail,
    used: [*]volatile virtio.Used,
    notify_addr: *volatile u32,
    free_desc: u16, // Next free descriptor
    last_used: u16, // Last seen used index
    queue_size: u16,

    pub fn init(desc: [*]volatile virtio.Desc, avail: [*]volatile virtio.Avail, used: [*]volatile virtio.Used, notify_addr: *volatile u32, queue_size: u16) VirtQueue {
        return VirtQueue{
            .desc = desc,
            .avail = avail,
            .used = used,
            .notify_addr = notify_addr,
            .free_desc = 0,
            .last_used = 0,
            .queue_size = queue_size,
        };
    }
};

// VirtIO block device structure
pub const VirtioBlkDevice = struct {
    mmio_base: usize,
    capacity: u64, // in 512-byte sectors
    blk_size: u32, // typically 512
    vq: VirtQueue,
    next_request_id: u32,

    // Physical addresses for DMA
    desc_phys: usize,
    avail_phys: usize,
    used_phys: usize,
    data_phys: usize,

    // Virtual addresses
    desc: [*]volatile virtio.Desc,
    avail: [*]volatile virtio.Avail,
    used: [*]volatile virtio.Used,

    // Data buffer for requests (pre-allocated)
    request_buffer: [*]volatile u8,
    status_buffer: [*]volatile u8,
    data_buffer: [*]volatile u8,
};

// Device instance
var blk_device: VirtioBlkDevice = undefined;
var is_initialized = false;

// Allocate VirtQueue memory with proper alignment
fn allocateVirtQueue(allocator: std.mem.Allocator, queue_size: u16) !struct {
    desc: [*]volatile virtio.Desc,
    avail: [*]volatile virtio.Avail,
    used: [*]volatile virtio.Used,
    desc_phys: usize,
    avail_phys: usize,
    used_phys: usize,
} {
    // For legacy virtio (version 1), all structures must be contiguous from PFN
    // Layout: desc_table | avail_ring | padding | used_ring (page-aligned)

    const desc_size = @sizeOf(virtio.Desc) * queue_size;
    const avail_size = 4 + (2 * queue_size) + 2; // flags + idx + ring + unused
    const used_size = 4 + (8 * queue_size); // flags + idx + ring

    // Calculate used ring offset (must be page-aligned for legacy)
    const used_offset = (desc_size + avail_size + 4095) & ~@as(usize, 4095);
    const total_size = used_offset + used_size;

    // Allocate with extra page for alignment
    const virt_mem = try allocator.alloc(u8, total_size + 4096);
    const base_virt_addr = @intFromPtr(virt_mem.ptr);
    const base_phys_addr = virtToPhys(base_virt_addr);

    // Align to page boundary for PFN
    const aligned_phys = (base_phys_addr + 4095) & ~@as(usize, 4095);
    const offset = aligned_phys - base_phys_addr;
    const aligned_virt = virt_mem.ptr[offset..virt_mem.len];

    // Setup pointers
    const desc = @as([*]volatile virtio.Desc, @ptrCast(@alignCast(@as([*]volatile u8, @ptrCast(aligned_virt.ptr)))));
    const avail = @as([*]volatile virtio.Avail, @ptrCast(@alignCast(@as([*]volatile u8, @ptrCast(desc)) + desc_size)));
    const used = @as([*]volatile virtio.Used, @ptrCast(@alignCast(@as([*]volatile u8, @ptrCast(desc)) + used_offset)));

    const desc_phys = aligned_phys;
    const avail_phys = desc_phys + desc_size;
    const used_phys = desc_phys + used_offset;

    return .{
        .desc = desc,
        .avail = avail,
        .used = used,
        .desc_phys = desc_phys,
        .avail_phys = avail_phys,
        .used_phys = used_phys,
    };
}

// Get a free descriptor from the queue
fn getDescIdx(vq: *VirtQueue) ?u16 {
    if (vq.free_desc >= vq.queue_size) {
        return null;
    }
    const idx = vq.free_desc;
    vq.free_desc += 1;
    return idx;
}

// Initialize VirtIO block device
pub fn initVirtioBlk(allocator: std.mem.Allocator, mmio_base: usize) !bool {
    kprint("Initializing VirtIO block device at 0x{x}...\n", .{mmio_base});

    // Step 1: Reset device
    virtio.setStatus(mmio_base, 0);
    while (virtio.getStatus(mmio_base) != 0) {}
    kprint("VirtIO-blk: Device reset\n", .{});

    // Step 2: Acknowledge device
    virtio.setStatus(mmio_base, virtio.Status.Acknowledge);
    while ((virtio.getStatus(mmio_base) & virtio.Status.Acknowledge) == 0) {}
    kprint("VirtIO-blk: Device acknowledged\n", .{});

    // Step 3: Driver is ready
    virtio.setStatus(mmio_base, virtio.Status.Acknowledge | virtio.Status.Driver);
    while ((virtio.getStatus(mmio_base) & virtio.Status.Driver) == 0) {}
    kprint("VirtIO-blk: Driver ready\n", .{});

    // Step 4: Read device config
    const config_base = mmio_base + virtio.MMIO.Config;
    const capacity = @as(*volatile u64, @ptrFromInt(config_base + 0x0)).*;
    const blk_size = @as(*volatile u32, @ptrFromInt(config_base + 0x14)).*;

    kprint("VirtIO-blk: Capacity={} sectors, Block size={} bytes\n", .{ capacity, blk_size });

    // Step 5: Negotiate features
    const driver_features: u64 = (1 << virtio.Block.FeatureBlkSize);
    virtio.negotiateFeatures(mmio_base, driver_features);

    // Step 6: Set FEATURES_OK
    virtio.setStatus(mmio_base, virtio.Status.Acknowledge | virtio.Status.Driver | virtio.Status.FeaturesOK);
    if ((virtio.getStatus(mmio_base) & virtio.Status.FeaturesOK) == 0) {
        kprint("VirtIO-blk: Features not accepted by device\n", .{});
        virtio.setStatus(mmio_base, virtio.Status.Failed);
        return error.FeaturesNotAccepted;
    }
    kprint("VirtIO-blk: Features OK\n", .{});

    // Step 7: Initialize virtqueue 0
    virtio.write32(mmio_base, virtio.MMIO.QueueSel, 0);
    const queue_num_max = virtio.read32(mmio_base, virtio.MMIO.QueueNumMax);
    if (queue_num_max < QUEUE_SIZE) {
        kprint("VirtIO-blk: Queue size {} too small, max={}\n", .{ QUEUE_SIZE, queue_num_max });
        return error.QueueTooSmall;
    }
    kprint("VirtIO-blk: Queue max size={}\n", .{queue_num_max});

    // Check version - legacy (v1) vs modern (v2)
    const version = virtio.read32(mmio_base, virtio.MMIO.Version);

    // Allocate queue memory
    const vq_mem = try allocateVirtQueue(allocator, QUEUE_SIZE);

    // Clear descriptor table
    for (0..QUEUE_SIZE) |i| {
        vq_mem.desc[i] = virtio.Desc{
            .addr = 0,
            .len = 0,
            .flags = 0,
            .next = 0,
        };
    }

    // Initialize avail ring (flags=0, idx=0)
    const avail_ptr = @as(*volatile virtio.Avail, @ptrCast(@volatileCast(vq_mem.avail)));
    avail_ptr.flags = 0;
    avail_ptr.idx = 0;

    // Initialize used ring (flags=0, idx=0)
    const used_ptr = @as(*volatile virtio.Used, @ptrCast(@volatileCast(vq_mem.used)));
    used_ptr.flags = 0;
    used_ptr.idx = 0;

    // Set queue size
    virtio.write32(mmio_base, virtio.MMIO.QueueNum, QUEUE_SIZE);

    // Configure queue addresses based on version
    if (version == 1) {
        // Legacy mode: use GuestPageSize and QueuePfn
        virtio.write32(mmio_base, virtio.MMIO.GuestPageSize, 4096);
        const pfn = vq_mem.desc_phys / 4096;
        virtio.write32(mmio_base, virtio.MMIO.QueuePfn, @truncate(pfn));
    } else {
        // Modern mode: use 64-bit addresses for each region
        virtio.write64(mmio_base, virtio.MMIO.QueueDescLow, virtio.MMIO.QueueDescHigh, vq_mem.desc_phys);
        virtio.write64(mmio_base, virtio.MMIO.QueueDriverLow, virtio.MMIO.QueueDriverHigh, vq_mem.avail_phys);
        virtio.write64(mmio_base, virtio.MMIO.QueueDeviceLow, virtio.MMIO.QueueDeviceHigh, vq_mem.used_phys);
        virtio.write32(mmio_base, virtio.MMIO.QueueReady, 1);
    }

    // Step 8: Set DRIVER_OK
    virtio.setStatus(mmio_base, virtio.Status.Acknowledge | virtio.Status.Driver | virtio.Status.FeaturesOK | virtio.Status.DriverOK);

    // Enable VirtIO interrupt in PLIC (device 7 at 0x10008000 uses IRQ 8)
    const virtio_irq: usize = 8;
    plic.plicEnableIrq(0, virtio_irq, true);

    // Allocate request buffers (pre-allocated for synchronous operations)
    const req_buffer = try allocator.alloc(u8, @sizeOf(virtio.Block.Request));
    const status_buffer = try allocator.alloc(u8, 1);
    const data_buffer = try allocator.alloc(u8, 4096);

    // Compute physical addresses for buffers
    const req_phys = virtToPhys(@intFromPtr(req_buffer.ptr));
    const status_phys = virtToPhys(@intFromPtr(status_buffer.ptr));
    const data_phys = virtToPhys(@intFromPtr(data_buffer.ptr));

    // Initialize device structure
    blk_device = VirtioBlkDevice{
        .mmio_base = mmio_base,
        .capacity = capacity,
        .blk_size = blk_size,
        .vq = VirtQueue.init(vq_mem.desc, vq_mem.avail, vq_mem.used, @ptrFromInt(mmio_base + virtio.MMIO.QueueNotify), QUEUE_SIZE),
        .next_request_id = 0,
        .desc_phys = vq_mem.desc_phys,
        .avail_phys = vq_mem.avail_phys,
        .used_phys = vq_mem.used_phys,
        .data_phys = 0,
        .desc = vq_mem.desc,
        .avail = vq_mem.avail,
        .used = vq_mem.used,
        .request_buffer = @ptrCast(req_buffer.ptr),
        .status_buffer = @ptrCast(status_buffer.ptr),
        .data_buffer = @ptrCast(data_buffer.ptr),
    };

    // Initialize descriptors for request chain (descriptors 0-2)
    blk_device.desc[0] = virtio.Desc{
        .addr = req_phys,
        .len = @sizeOf(virtio.Block.Request),
        .flags = virtio.DescFlags.Next,
        .next = 1,
    };
    blk_device.desc[1] = virtio.Desc{
        .addr = data_phys,
        .len = 4096,
        .flags = virtio.DescFlags.Write | virtio.DescFlags.Next,
        .next = 2,
    };
    blk_device.desc[2] = virtio.Desc{
        .addr = status_phys,
        .len = 1,
        .flags = virtio.DescFlags.Write,
        .next = 0,
    };

    is_initialized = true;
    return true;
}

// Submit a request to the device and wait for completion
// This is a synchronous blocking operation
fn submitRequest(blk_dev: *VirtioBlkDevice) !u8 {
    const vq = &blk_dev.vq;
    blk_dev.next_request_id += 1;

    // Get current available index
    const current_idx = vq.avail[0].idx;
    const ring_index = current_idx % QUEUE_SIZE;

    // Add descriptor chain head (0) to available ring
    // Avail ring layout: [flags:u16][idx:u16][ring:u16[]]
    const avail_ring = @as([*]volatile u16, @ptrCast(@alignCast(@as([*]volatile u8, @ptrCast(vq.avail)) + 4)));
    avail_ring[ring_index] = 0; // Descriptor chain head is always 0

    // Memory barrier - ensure avail ring writes are visible before updating idx
    asm volatile ("fence" ::: .{ .memory = true });

    // Update available index (makes request visible to device)
    vq.avail[0].idx = current_idx + 1;

    // Memory barrier - ensure idx update is visible before notify
    asm volatile ("fence" ::: .{ .memory = true });

    // Notify device - write queue number (0) to QueueNotify register
    vq.notify_addr.* = 0;

    // Wait for completion
    var timeout: usize = 10000000;
    while (timeout > 0) : (timeout -= 1) {
        asm volatile ("fence" ::: .{ .memory = true });
        const used_ring_base: usize = @intFromPtr(vq.used);
        const used_idx = @as(*volatile u16, @ptrCast(@alignCast(@as([*]volatile u8, @ptrFromInt(used_ring_base + 2))))).*;

        if (used_idx != vq.last_used) {
            const elem_offset = used_ring_base + 4 + (vq.last_used % QUEUE_SIZE) * @sizeOf(virtio.UsedElem);
            const used_elem = @as(*volatile virtio.UsedElem, @ptrCast(@alignCast(@as([*]volatile u8, @ptrFromInt(elem_offset)))));
            if (used_elem.id == 0) {
                vq.last_used = used_idx;
                return blk_dev.status_buffer[0];
            }
            vq.last_used += 1;
        }
    }

    return error.Timeout;
}

// Read blocks from device
pub fn readBlocks(sector: u64, buffer: []u8) !usize {
    if (!is_initialized) return error.NotInitialized;

    // Limit to 4KB (8 sectors)
    if (buffer.len > 4096) return error.BufferTooLarge;
    if (sector >= blk_device.capacity) return error.SectorOutOfRange;

    // Setup request
    const req = @as(*volatile virtio.Block.Request, @ptrCast(@alignCast(blk_device.request_buffer)));
    req.type = virtio.Block.ReqIn;
    req.reserved = 0;
    req.sector = sector;

    // Setup data descriptor for read (device writes)
    blk_device.desc[1].flags = virtio.DescFlags.Write | virtio.DescFlags.Next;
    blk_device.desc[1].len = @truncate(buffer.len);

    // Submit request
    const status = try submitRequest(&blk_device);
    if (status != virtio.Block.StatusOK) {
        return error.IOError;
    }

    // Copy data to buffer
    @memcpy(buffer, blk_device.data_buffer[0..buffer.len]);

    return buffer.len;
}

// Write blocks to device
pub fn writeBlocks(sector: u64, buffer: []const u8) !usize {
    if (!is_initialized) return error.NotInitialized;

    // Limit to 4KB (8 sectors)
    if (buffer.len > 4096) return error.BufferTooLarge;
    if (sector >= blk_device.capacity) return error.SectorOutOfRange;

    // Copy data to DMA buffer
    @memcpy(blk_device.data_buffer[0..buffer.len], buffer);

    // Setup request
    const req = @as(*volatile virtio.Block.Request, @ptrCast(@alignCast(blk_device.request_buffer)));
    req.type = virtio.Block.ReqOut;
    req.reserved = 0;
    req.sector = sector;

    // Setup data descriptor for write (device reads)
    blk_device.desc[1].flags = virtio.DescFlags.Next; // No WRITE flag
    blk_device.desc[1].len = @truncate(buffer.len);

    // Submit request
    const status = try submitRequest(&blk_device);
    if (status != virtio.Block.StatusOK) {
        return error.IOError;
    }

    return buffer.len;
}

// TODO: remove single instance implement.
pub fn instance() *VirtioBlkDevice {
    return &blk_device;
}

pub fn blkRead(_: *anyopaque, lba: u64, buffer: []u8) anyerror!usize {
    // Convert block number to sector (512-byte sectors, 8 sectors per 4KB block)
    const sectors = LOGICAL_BLOCK_SIZE / SECTOR_SIZE;
    return readBlocks(lba * sectors, buffer);
}

pub fn blkWrite(_: *anyopaque, lba: u64, buffer: []const u8) anyerror!usize {
    const sectors = LOGICAL_BLOCK_SIZE / SECTOR_SIZE;
    return writeBlocks(lba * sectors, buffer);
}

// Get device capacity in bytes
pub fn getCapacity() u64 {
    if (!is_initialized) return 0;
    return blk_device.capacity * blk_device.blk_size;
}

// Check if device is initialized
pub fn isInitialized() bool {
    return is_initialized;
}

// Get block size
pub fn getBlockSize() u32 {
    if (!is_initialized) return 0;
    return blk_device.blk_size;
}
