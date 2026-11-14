const arch = @import("arch");
const board = @import("board");
const board_cfg = @import("board").config;

const io = arch.io;
const riscv = arch.riscv;

const utils = @import("common").utils;
const boot_trace = board_cfg.boot_trace;
const uart = switch (board_cfg.uart0.kind) {
    .ns16550 => @import("ns16550.zig").ns16550,
    .dw_apb => @import("dw_apb_uart.zig").dw_apb_uart,
    else => @compileError("unsupported UART driver"),
};

pub const PLIC_BASE: usize = board_cfg.plic.base;
pub const PLIC_MAX_IRQS: usize = board_cfg.plic.num_sources;

// irq extern interrupt enable
const SIE_SEIE: usize = riscv.SIE_SEIE;

pub const IrqHandler = *const fn () void;

// @splat(null) mean "[_]?IrqHandler{null} ** (PLIC_MAX_IRQS + 1);"
var irq_handlers: [PLIC_MAX_IRQS + 1]?IrqHandler = @splat(null);

fn bootTrace(comptime message: []const u8) void {
    if (comptime boot_trace) {
        for (message) |c| {
            if (c == '\n') uart.put('\r');
            uart.put(c);
        }
    }
}

fn bootTraceHex(value: u64) void {
    if (comptime boot_trace) {
        uart.put('0');
        uart.put('x');

        var shift: u6 = 60;
        while (true) {
            const nibble: u8 = @truncate((value >> shift) & 0xf);
            uart.put(if (nibble < 10) '0' + nibble else 'a' + nibble - 10);
            if (shift == 0) break;
            shift -= 4;
        }
    }
}

pub fn registerIrq(hwirq: u32, handler: IrqHandler) void {
    irq_handlers[hwirq] = handler;
}

// configure interrupts priority
inline fn plicPriority(hwirq: usize) usize {
    return PLIC_BASE + (hwirq * 4);
}

// configure interrupts pending bit, one bit -> one interrupt
inline fn plicPending(hwirq: usize) usize {
    return PLIC_BASE + 0x1000 + (((hwirq / 32) * 4));
}

// Although it is called 'M-mode' PLIC_MENABLE, CPU_TO_HART(0)=1 accesses the S-mode context.

// configure interrupts enabled
inline fn plicMenable(context: usize) usize {
    return PLIC_BASE + 0x2000 + ((context * 0x80));
}

// configure interrupts mthreshold,
// if 'priority' > 'mthreshold' then the interrupt will trigger
inline fn plicMthreshold(context: usize) usize {
    return PLIC_BASE + 0x200000 + (context * 0x1000);
}

// Interrupt Claim Process
inline fn plicMclaim(context: usize) usize {
    return PLIC_BASE + 0x200004 + (context * 0x1000);
}

inline fn plicMcomplete(context: usize) usize {
    return PLIC_BASE + 0x200004 + (context) * 0x1000;
}

pub fn plicSetPrority(hwirq: usize, prio: u32) void {
    const reg = plicPriority(hwirq);

    io.mmioWrite(u32, prio, reg);
}

pub fn plicEnableIrq(cpu: usize, hwirq: usize, enable: bool) void {
    // For 32-bit integers, the right operand must be of u5 type.
    const hwirq_mask = @as(u32, 1) << @intCast(hwirq % 32);
    const context = board.cpu_to_context(cpu);
    const reg = plicMenable(context) + (4 * (hwirq / 32));

    if (enable) {
        utils.kprint("reg: 0x{x}, hwirq:{}, enabled: {}\n", .{ reg, hwirq, enable });
        io.mmioWrite(u32, io.mmioRead(u32, reg) | hwirq_mask, reg);
    } else {
        io.mmioWrite(u32, io.mmioRead(u32, reg) & ~hwirq_mask, reg);
    }
}

pub fn plicInit() i32 {
    for (0..board_cfg.max_cpus) |i| {
        const context = board.cpu_to_context(i);
        // congigure m-mode all cpu hart interrupt threshold to 0
        io.mmioWrite(u32, 0, plicMthreshold(context));

        for (1..PLIC_MAX_IRQS + 1) |hwirq| {
            // Disabled all external interrupts int the PLIC
            plicEnableIrq(i, hwirq, false);

            // Pre-set the priority of all interrupt numbers to 1
            plicSetPrority(hwirq, 1);
        }
    }

    io.setCsr("sie", SIE_SEIE);
    return 0;
}

pub fn handlerPlicIrq() void {
    bootTrace("P: handler function enter\n");
    const cpu = riscv.riscvReadTp();
    const context = board.cpu_to_context(cpu);
    const claim = plicMclaim(context);

    if (comptime boot_trace) {
        bootTrace("P: handler enter context=");
        bootTraceHex(context);
        bootTrace(" claim=");
        bootTraceHex(claim);
        bootTrace("\n");
    }

    while (true) {
        bootTrace("P: before claim read\n");
        const hwirq = io.mmioRead(u32, claim);
        if (comptime boot_trace) {
            bootTrace("P: claimed hwirq=");
            bootTraceHex(hwirq);
            bootTrace("\n");
        }
        if (hwirq == 0) break;

        if (hwirq > PLIC_MAX_IRQS) {
            bootTrace("P: claimed IRQ outside PLIC range\n");
        } else if (irq_handlers[hwirq]) |handler| {
            if (comptime boot_trace) {
                bootTrace("P: before IRQ handler\n");
            }
            handler();
            bootTrace("P: after IRQ handler\n");
        } else {
            bootTrace("P: claimed IRQ has no handler\n");
        }

        bootTrace("P: before complete\n");
        io.mmioWrite(u32, hwirq, claim);
        bootTrace("P: after complete\n");
    }
    bootTrace("P: claim drained\n");
    io.setCsr("sie", SIE_SEIE);
    bootTrace("P: handler leave\n");
}
