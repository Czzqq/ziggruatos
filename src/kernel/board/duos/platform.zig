pub const config = @import("config.zig");

// OpenSBI exposes one S-mode interrupt context per hart. The DuoS DTS
// currently describes a single RISC-V CPU for the Linux/high-level domain.
pub inline fn cpu_to_context(cpu: usize) usize {
    return cpu * 2 + 1;
}
