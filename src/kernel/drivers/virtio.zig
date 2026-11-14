const std = @import("std");

const kprint = @import("common").utils.kprint;

// VirtIO MMIO registers (from QEMU virtio-mmio spec)
pub const MMIO = struct {
    pub const MagicValue = 0x000; // R: 0x74726976 ("virt")
    pub const Version = 0x004; // R: 0x2 (legacy=1, modern=2)
    pub const DeviceID = 0x008; // R: Device type (e.g., 2 for block device)
    pub const VendorID = 0x00C; // R: 0x554D4551 ("QEMU")
    pub const DeviceFeatures = 0x010; // R
    pub const DeviceFeaturesSel = 0x014; // W
    pub const DriverFeatures = 0x020; // W
    pub const DriverFeaturesSel = 0x024; // W
    pub const GuestPageSize = 0x028; // W (legacy only)
    pub const QueueSel = 0x030; // W
    pub const QueueNumMax = 0x034; // R
    pub const QueueNum = 0x038; // W
    pub const QueueAlign = 0x03C; // W (legacy only)
    pub const QueuePfn = 0x040; // W (legacy only)
    pub const QueueReady = 0x044; // RW
    pub const QueueNotify = 0x050; // W
    pub const InterruptStatus = 0x060; // R
    pub const InterruptACK = 0x064; // W
    pub const Status = 0x070; // RW
    pub const QueueDescLow = 0x080; // W
    pub const QueueDescHigh = 0x084; // W
    pub const QueueDriverLow = 0x090; // W
    pub const QueueDriverHigh = 0x094; // W
    pub const QueueDeviceLow = 0x0A0; // W
    pub const QueueDeviceHigh = 0x0A4; // W
    pub const ConfigGeneration = 0x0FC; // R
    pub const Config = 0x100; // Device-specific config
};

// VirtIO device status bits
pub const Status = struct {
    pub const Acknowledge = 1;
    pub const Driver = 2;
    pub const DriverOK = 4;
    pub const FeaturesOK = 8;
    pub const Failed = 128;
};

// VirtIO device types
pub const DeviceType = enum(u32) {
    None = 0,
    Network = 1,
    Block = 2,
    Console = 3,
    Entropy = 4,
    GPU = 16,
    Input = 18,
    // ... more types
};

// VirtIO block device specific
pub const Block = struct {
    // Block-specific features
    pub const FeatureSizeMax = 0;
    pub const FeatureSegMax = 1;
    pub const FeatureGeometry = 4;
    pub const FeatureRO = 5;
    pub const FeatureBlkSize = 6;
    pub const FeatureTopolog = 10;
    pub const FeatureConfigWCE = 11;
    pub const FeatureMQ = 12;
    pub const FeatureDiscard = 13;
    pub const FeatureWriteZeroes = 14;

    // Block request types
    pub const ReqIn = 0;
    pub const ReqOut = 1;
    pub const ReqFlush = 4;
    pub const ReqDiscard = 11;
    pub const ReqWriteZeroes = 13;

    // Block request status
    pub const StatusOK = 0;
    pub const StatusIOError = 1;
    pub const StatusUnsupp = 2;

    // Config space layout for block device
    pub const Config = extern struct {
        capacity: u64,
        size_max: u32,
        seg_max: u32,
        geometry: extern struct {
            cylinders: u16,
            heads: u8,
            sectors: u8,
        },
        blk_size: u32,
    };

    // Request header
    pub const Request = extern struct {
        type: u32,
        reserved: u32,
        sector: u64,
    };
};

// VirtQueue descriptor
pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

// VirtQueue available ring
pub const Avail = struct {
    flags: u16,
    idx: u16,
    ring: [0]u16, // Variable size
};

// VirtQueue used element
pub const UsedElem = extern struct {
    id: u32,
    len: u32,
};

// VirtQueue used ring
pub const Used = struct {
    flags: u16,
    idx: u16,
    ring: [0]UsedElem, // Variable size
};

// Descriptor flags
pub const DescFlags = struct {
    pub const Next = 1;
    pub const Write = 2;
    pub const Indirect = 4;
};

// QEMU RISC-V virt machine VirtIO MMIO base addresses
pub const VIRTIO_MMIO_BASE: usize = 0x10001000;
pub const VIRTIO_MMIO_SIZE: usize = 0x1000;

/// Read 32-bit register from MMIO
pub fn read32(base: usize, offset: usize) u32 {
    const addr = @as(*volatile u32, @ptrFromInt(base + offset));
    return addr.*;
}

/// Write 32-bit register to MMIO
pub fn write32(base: usize, offset: usize, value: u32) void {
    const addr = @as(*volatile u32, @ptrFromInt(base + offset));
    addr.* = value;
}

/// Read 64-bit register from MMIO (may need two 32-bit reads)
pub fn read64(base: usize, offset_low: usize, offset_high: usize) u64 {
    const low = read32(base, offset_low);
    const high = read32(base, offset_high);
    return (@as(u64, high) << 32) | low;
}

/// Write 64-bit register to MMIO (may need two 32-bit writes)
pub fn write64(base: usize, offset_low: usize, offset_high: usize, value: u64) void {
    write32(base, offset_low, @truncate(value));
    write32(base, offset_high, @truncate(value >> 32));
}

/// Initialize VirtIO MMIO transport
/// Returns true if a supported device is found
pub fn initVirtIO(mmio_base: usize, expected_type: DeviceType) bool {
    const magic = read32(mmio_base, MMIO.MagicValue);
    if (magic != 0x74726976) {
        kprint("VirtIO: Invalid magic value: 0x{x}\n", .{magic});
        return false;
    }

    const version = read32(mmio_base, MMIO.Version);
    const device_id = read32(mmio_base, MMIO.DeviceID);
    const vendor_id = read32(mmio_base, MMIO.VendorID);

    kprint("VirtIO: Found device at 0x{x}, version={}, type={}, vendor=0x{x}\n", .{
        mmio_base, version, device_id, vendor_id,
    });

    if (device_id != @intFromEnum(expected_type)) {
        kprint("VirtIO: Expected type {}, found {}\n", .{
            @intFromEnum(expected_type), device_id,
        });
        return false;
    }

    return true;
}

/// Negotiate features with device
pub fn negotiateFeatures(mmio_base: usize, driver_features: u64) void {
    // Select feature bits 0-31
    write32(mmio_base, MMIO.DeviceFeaturesSel, 0);
    const device_features_lo = read32(mmio_base, MMIO.DeviceFeatures);

    // Select feature bits 32-63
    write32(mmio_base, MMIO.DeviceFeaturesSel, 1);
    const device_features_hi = read32(mmio_base, MMIO.DeviceFeatures);

    const device_features = (@as(u64, device_features_hi) << 32) | device_features_lo;
    const negotiated = device_features & driver_features;

    kprint("VirtIO: Device features: 0x{x:0>16}, negotiated: 0x{x:0>16}\n", .{
        device_features, negotiated,
    });

    // Write negotiated features
    write32(mmio_base, MMIO.DriverFeaturesSel, 0);
    write32(mmio_base, MMIO.DriverFeatures, @truncate(negotiated));

    write32(mmio_base, MMIO.DriverFeaturesSel, 1);
    write32(mmio_base, MMIO.DriverFeatures, @truncate(negotiated >> 32));
}

/// Set device status
pub fn setStatus(mmio_base: usize, status: u32) void {
    write32(mmio_base, MMIO.Status, status);
}

/// Get device status
pub fn getStatus(mmio_base: usize) u32 {
    return read32(mmio_base, MMIO.Status);
}

// QEMU virt machine has 8 virtio-mmio devices
// Each device occupies 0x1000 (4096) bytes
pub const VIRTIO_MMIO_DEVICES: [8]usize = .{
    0x10001000, // Device 0
    0x10002000, // Device 1
    0x10003000, // Device 2
    0x10004000, // Device 3
    0x10005000, // Device 4
    0x10006000, // Device 5
    0x10007000, // Device 6
    0x10008000, // Device 7
};

/// Scan for a VirtIO device of the specified type
/// Returns the base address if found, 0 otherwise
pub fn scanForDevice(expected_type: DeviceType) ?usize {
    for (VIRTIO_MMIO_DEVICES) |base| {
        const magic = read32(base, MMIO.MagicValue);
        if (magic != 0x74726976) continue; // Not a VirtIO device

        const device_id = read32(base, MMIO.DeviceID);
        if (device_id == @intFromEnum(expected_type)) {
            return base;
        }
    }
    return 0;
}
