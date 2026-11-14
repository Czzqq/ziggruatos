const io = @import("arch").io;
const board_cfg = @import("board").config;

const UART_BASE = board_cfg.uart0.base;
const UART_REGISTER = switch (board_cfg.uart0.reg_width) {
    1 => u8,
    4 => u32,
    else => @compileError("unsupported UART register width"),
};

const UART_DAT: usize = 0x00;
const UART_IER: usize = 0x01;
const UART_IIR: usize = 0x02;

const UART_FCR: usize = 0x02;
const UART_LCR: usize = 0x03;
const UART_MCR: usize = 0x04;
const UART_LSR: usize = 0x05;
const UART_MSR: usize = 0x06;

const UART_DLL: usize = 0x00;
const UART_DLM: usize = 0x01;

const UART_LSR_ERROR: usize = 0x80;
const UART_LSR_EMPTY: usize = 0x40;
const UART_LSR_TFE: usize = 0x20;
const UART_LSR_BI: usize = 0x10;
const UART_LSR_FE: usize = 0x08;
const UART_LSR_PE: usize = 0x04;
const UART_LSR_OE: usize = 0x02;
const UART_LSR_DR: usize = 0x01;

inline fn registerAddress(offset: usize) usize {
    return UART_BASE + (offset << board_cfg.uart0.reg_shift);
}

inline fn readRegister(offset: usize) UART_REGISTER {
    return io.mmioRead(UART_REGISTER, registerAddress(offset));
}

inline fn writeRegister(offset: usize, value: anytype) void {
    io.mmioWrite(UART_REGISTER, @intCast(value), registerAddress(offset));
}

pub const ns16550 = struct {
    pub fn init() void {
        const divisor: u32 = board_cfg.uart0.clock / (16 * board_cfg.uart0.baud);

        // disabled interrupt
        writeRegister(UART_IER, 0x0);

        // enable DLAB (set baud rate divisor)
        writeRegister(UART_LCR, 0x80);
        writeRegister(UART_DLL, @as(u32, @truncate(divisor)));
        writeRegister(UART_DLM, @as(u32, @truncate(divisor >> 8)));

        // 8bits, no parity, one stop bit
        writeRegister(UART_LCR, 0x3);

        // enable FIFO, empty FIFO, set 14 bytes threshold
        writeRegister(UART_FCR, 0xc7);
    }

    pub fn enableInterrupt() void {
        // enable received-data-available interrupt
        writeRegister(UART_IER, 0x1);
    }

    pub fn put(c: u8) void {
        while ((readRegister(UART_LSR) & UART_LSR_EMPTY) == 0) {
            // busy wait until the uart is ready to send
            continue;
        }

        writeRegister(UART_DAT, c);
    }

    pub fn rxReady() bool {
        return ((readRegister(UART_LSR) & UART_LSR_DR) != 0);
    }

    pub fn get() ?u8 {
        // If buffer is empty, check the hardware
        if (rxReady()) {
            return @truncate(readRegister(UART_DAT));
        } else {
            return null;
        }
    }

    pub fn interruptStatus() u32 {
        return readRegister(UART_IIR);
    }

    pub fn isBusyDetect(iir: u32) bool {
        _ = iir;
        return false;
    }

    pub fn clearBusyDetect() void {}
};
