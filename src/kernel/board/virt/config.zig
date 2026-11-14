// MUST keep host could compile this zig source code

pub const max_cpus: usize = 2;
pub const linear_image = false;
pub const boot_trace = false;

pub const dram = .{ .base = 0x8000_0000, .size = 32 * 1024 * 1024 };

pub const kernel_load = 0x8020_0000;
pub const kernel_image_end = 0x8030_0000;

pub const uart0 = .{
    .kind = .ns16550,
    .base = 0x1000_0000,
    .irq = 10,
    .clock = 1_843_200,
    .baud = 115_200,
    .reg_shift = 0,
    .reg_width = 1,
};
pub const plic = .{ .base = 0xc00_0000, .num_sources = 53 };
pub const timer = .{ .freq = 10_000_000 };
pub const virtio_mmio = .{ .base = 0x1000_1000, .stride = 0x1000, .count = 8, .irq_base = 1 };

pub const initramfs = .{ // QEMU: load addr = kernel_image_end + dram.size
    .base = 0x8230_0000,
    .max_size = 16 * 1024 * 1024,
    .embedded = false,
};

pub const kernel_memory = .{
    .base = kernel_image_end, // 0x8030_0000
    .size = initramfs.base - kernel_image_end,
};
