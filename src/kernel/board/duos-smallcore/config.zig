pub const max_cpus: usize = 1;
pub const linear_image = true;
pub const mmu_supported = false;
pub const boot_trace = false;

pub const dram = .{ .base = 0x9f00_0000, .size = 16 * 1024 * 1024 };
pub const kernel_load = dram.base;
pub const kernel_memory = .{
    .base = 0x9f80_0000,
    .size = 8 * 1024 * 1024,
};

pub const uart0 = .{
    .kind = .dw_apb,
    .base = 0x0415_0000,
    .irq = 0,
    .clock = 25_000_000,
    .baud = 115_200,
    .reg_shift = 2,
    .reg_width = 4,
};

pub const plic = .{ .base = 0x7000_0000, .num_sources = 101 };
pub const timer = .{ .freq = 25_000_000 };
pub const initramfs = .{ .base = 0, .max_size = 0, .embedded = false };
