const io = @import("arch").io;
const board_cfg = @import("board").config;

const UART_BASE = board_cfg.uart0.base;
const UART_REGISTER = switch (board_cfg.uart0.reg_width) {
    1 => u8,
    4 => u32,
    else => @compileError("unsupported DW APB UART register width"),
};

const UART_DAT: usize = 0x00;
const UART_IER: usize = 0x01;
const UART_FCR: usize = 0x02;
const UART_LCR: usize = 0x03;
const UART_MCR: usize = 0x04;
const UART_LSR: usize = 0x05;
const UART_DLL: usize = 0x00;
const UART_DLM: usize = 0x01;

// DW APB UART extension registers use byte offsets, unlike the shifted
// 16550-compatible register bank selected by the device tree.
const DW_UART_USR: usize = 0x7c;
const DW_UART_DLF: usize = 0xc0;
const DW_UART_UCV: usize = 0xf8;

const UART_LCR_DLAB: u32 = 0x80;
const UART_LCR_8N1: u32 = 0x03;
const UART_FCR_ENABLE_AND_CLEAR: u32 = 0xc7;
const UART_MCR_DTR_RTS: u32 = 0x03;
const UART_IER_RX_AVAILABLE: u32 = 0x01;
const UART_IIR_BUSY: u32 = 0x07;
const UART_LSR_THRE: u32 = 0x20;
const UART_LSR_DR: u32 = 0x01;

inline fn registerAddress(offset: usize) usize {
    return UART_BASE + (offset << board_cfg.uart0.reg_shift);
}

inline fn readRegister(offset: usize) UART_REGISTER {
    return io.mmioRead(UART_REGISTER, registerAddress(offset));
}

inline fn writeRegister(offset: usize, value: u32) void {
    io.mmioWrite(UART_REGISTER, @intCast(value), registerAddress(offset));
}

inline fn readExtended(offset: usize) u32 {
    return io.mmioRead(u32, UART_BASE + offset);
}

inline fn writeExtended(offset: usize, value: u32) void {
    io.mmioWrite(u32, value, UART_BASE + offset);
}

fn detectDlfSize() ?u5 {
    if (readExtended(DW_UART_UCV) == 0) {
        return null;
    }

    writeExtended(DW_UART_DLF, 0xffff_ffff);
    const writable = readExtended(DW_UART_DLF);
    writeExtended(DW_UART_DLF, 0);

    if (writable == 0) {
        return null;
    }

    const bits: u6 = 32 - @clz(writable);
    return @intCast(@min(bits, 31));
}

fn roundClosest(numerator: u64, denominator: u64) u64 {
    return (numerator + denominator / 2) / denominator;
}

fn configureBaudRate(dlf_size: ?u5) void {
    const baud_16: u32 = board_cfg.uart0.baud * 16;
    const divisor: u32 = board_cfg.uart0.clock / baud_16;
    const remainder: u32 = board_cfg.uart0.clock % baud_16;

    const fraction: u32 = if (dlf_size) |bits| fraction: {
        const rounded = roundClosest(@as(u64, remainder) << bits, baud_16);
        const max_fraction = (@as(u64, 1) << bits) - 1;
        break :fraction @intCast(@min(rounded, max_fraction));
    } else 0;

    writeExtended(DW_UART_DLF, fraction);
    writeRegister(UART_LCR, UART_LCR_DLAB);
    writeRegister(UART_DLL, divisor);
    writeRegister(UART_DLM, divisor >> 8);
}

pub const dw_apb_uart = struct {
    pub fn init() void {
        // Keep receive interrupts off until PLIC and the trap vector are ready.
        writeRegister(UART_IER, 0);

        configureBaudRate(detectDlfSize());

        // 8 data bits, no parity, one stop bit.
        writeRegister(UART_LCR, UART_LCR_8N1);
        writeRegister(UART_FCR, UART_FCR_ENABLE_AND_CLEAR);
        writeRegister(UART_MCR, UART_MCR_DTR_RTS);
    }

    pub fn enableInterrupt() void {
        writeRegister(UART_IER, UART_IER_RX_AVAILABLE);
    }

    pub fn put(c: u8) void {
        while ((readRegister(UART_LSR) & UART_LSR_THRE) == 0) {
            // Wait until the transmit holding register is empty.
        }
        writeRegister(UART_DAT, c);
    }

    pub fn rxReady() bool {
        return (readRegister(UART_LSR) & UART_LSR_DR) != 0;
    }

    pub fn lineStatus() u32 {
        return readRegister(UART_LSR);
    }

    pub fn interruptStatus() u32 {
        // Offset 2 aliases IIR on reads and FCR on writes.
        return readRegister(UART_FCR);
    }

    pub fn isBusyDetect(iir: u32) bool {
        return (iir & 0x0f) == UART_IIR_BUSY;
    }

    pub fn clearBusyDetect() void {
        // Reading USR acknowledges DesignWare's busy-detect interrupt.
        _ = readExtended(DW_UART_USR);
    }

    pub fn get() ?u8 {
        if (!rxReady()) {
            return null;
        }
        return @truncate(readRegister(UART_DAT));
    }
};
