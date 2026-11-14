// Milk-V DuoS (SG2000/CV181x), RISC-V C906 supervisor-mode payload.

pub const max_cpus: usize = 1;
pub const linear_image = true;
pub const thead_pte_extensions = true;
pub const boot_trace = false;

pub const dram = .{ .base = 0x8000_0000, .size = 512 * 1024 * 1024 };

pub const kernel_load = 0x8020_0000;

pub const uart0 = .{
    .kind = .dw_apb,
    .base = 0x0414_0000,
    .irq = 44,
    .clock = 25_000_000,
    .baud = 115_200,
    .reg_shift = 2,
    .reg_width = 4,
};

pub const plic = .{ .base = 0x7000_0000, .num_sources = 101 };
pub const timer = .{ .freq = 25_000_000 };

// Keep the payload's first 14 MiB untouched for the kernel and embedded
// initramfs. The final 2 MiB belong to the C906L FreeRTOS image.
pub const kernel_memory = .{
    .base = 0x8100_0000,
    .size = 0x9FE0_0000 - 0x8100_0000,
};

pub const initramfs = .{
    .base = 0,
    .max_size = 0,
    .embedded = true,
};
