//! Public suface of the device drivser.
const board_cfg = @import("board").config;

pub const plic = @import("plic.zig");
pub const virtio = @import("virtio.zig");
pub const virtio_blk = @import("virtio_blk.zig");
pub const ns16550 = @import("ns16550.zig");
pub const dw_apb_uart = @import("dw_apb_uart.zig");

pub const uart = switch (board_cfg.uart0.kind) {
    .ns16550 => ns16550.ns16550,
    .dw_apb => dw_apb_uart.dw_apb_uart,
    else => @compileError("unsupported UART driver"),
};
