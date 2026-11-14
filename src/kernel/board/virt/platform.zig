pub const config = @import("config.zig");

// The PLIC interrupt controller supports multiple interrupt hardware contexts,
// each hart may contain multiple interrupt contexts, and each interrupt context contains a set of interrupt-related control registers.
// This func maps from CPU to hart, and then maps to the M mode interrupt context.
//
// For the QEMU Virt platform, CPU0 maps to hart1, CPU1 maps to hart3, and so on.
// Each hart has M mode and S mode interrupt contexts.
// The CPU_TO_CONTEXT func is used to map the M mode interrupt context corresponding to the hart of the CPU.
pub inline fn cpu_to_context(cpu: usize) usize {
    return (cpu * 2 + 1);
}
