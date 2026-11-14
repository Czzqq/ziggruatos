const std = @import("std");
const task = @import("task.zig");

const arch = @import("arch");
const riscv = arch.riscv;

const SpinLock = arch.spinlock.SpinLock;

const board_cfg = @import("board").config;
const boot_trace = board_cfg.boot_trace;
const utils = @import("common").utils;
const uart = @import("drivers").uart;
const plic = @import("drivers").plic;

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

// Circular buffer for serial input
const BUFFER_SIZE = 1024;
const Buffer = struct {
    data: [BUFFER_SIZE]u8,
    read_idx: usize,
    write_idx: usize,
    console_lock: SpinLock = SpinLock.init("serial_buffer_lock"),

    pub fn init() Buffer {
        return Buffer{
            .data = @splat(0),
            .read_idx = 0,
            .write_idx = 0,
        };
    }

    pub fn is_empty(self: *const Buffer) bool {
        return self.read_idx == self.write_idx;
    }

    pub fn is_full(self: *const Buffer) bool {
        return (self.write_idx + 1) % BUFFER_SIZE == self.read_idx;
    }

    pub fn put(self: *Buffer, c: u8) bool {
        // // Acquire lock before accessing buffer data
        // self.console_lock.acquire();
        // defer self.console_lock.release();

        if (self.is_full()) {
            return false; // Buffer overflow
        }
        self.data[self.write_idx] = c;
        self.write_idx = (self.write_idx + 1) % BUFFER_SIZE;
        return true;
    }

    pub fn get(self: *Buffer) ?u8 {
        // // Acquire lock before accessing buffer data
        // self.console_lock.acquire();
        // defer self.console_lock.release();

        if (self.is_empty()) {
            return null; // Buffer empty
        }
        const c = self.data[self.read_idx];
        self.read_idx = (self.read_idx + 1) % BUFFER_SIZE;
        return c;
    }

    pub fn unput(self: *Buffer) bool {
        if (self.is_empty()) {
            return false;
        }

        // backspace write_idx
        if (self.write_idx == 0) {
            self.write_idx = BUFFER_SIZE - 1;
        } else {
            self.write_idx -= 1;
        }

        return true;
    }
};

// Create a buffer instance
var input_buffer = Buffer.init();

// UART input echo and normal writes both use uartPut, so this tracks the
// actual console line even when a shell prompt does not end in a newline.
var output_line_start: bool = true;

pub const Serial = struct {
    pub fn atLineStart() bool {
        return @atomicLoad(bool, &output_line_start, .monotonic);
    }

    pub fn uartInit() void {
        uart.init();
    }

    pub fn uartPut(c: u8) void {
        if (c == '\n') {
            uart.put('\r');
        }
        uart.put(c);
        @atomicStore(bool, &output_line_start, c == '\n', .monotonic);
    }

    pub fn uartGet() ?u8 {
        // Check if there's data in the buffer
        if (input_buffer.get()) |c| {
            return c;
        }
        return uart.get();
    }

    pub fn write(data: []const u8) void {
        for (data) |c|
            uartPut(c);
    }

    pub fn handleUartIrq() void {
        bootTrace("U: handler enter\n");
        const iir = uart.interruptStatus();
        if (comptime boot_trace) {
            bootTrace("U: lsr=");
            bootTraceHex(uart.lineStatus());
            bootTrace(" iir=");
            bootTraceHex(iir);
            bootTrace("\n");
        }

        if (uart.isBusyDetect(iir)) {
            uart.clearBusyDetect();
            bootTrace("U: busy-detect acknowledged\n");
            return;
        }

        input_buffer.console_lock.acquire();
        bootTrace("U: input lock acquired\n");

        // Read all available data from the UART
        var count: usize = 0;
        while (uart.rxReady()) {
            var c = uart.get().?;
            count += 1;
            if (comptime boot_trace) {
                bootTrace("U: rx byte=");
                bootTraceHex(c);
                bootTrace(" lsr=");
                bootTraceHex(uart.lineStatus());
                bootTrace(" iir=");
                bootTraceHex(uart.interruptStatus());
                bootTrace("\n");
            }

            if (c == '\r') {
                c = '\n';
                uartPut('\n');
                _ = input_buffer.put(c);
            } else if (c >= 32 and c < 127) {
                uartPut(c); // echo
                _ = input_buffer.put(c);
            } // other control character（e.g. Ctrl+C, Ctrl+D)
            else {
                // for unprocess contol character, choose：
                // 1. ignore
                // 2. let application process with putting buffer
                _ = input_buffer.put(c);
            }
        }
        if (comptime boot_trace) {
            bootTrace("U: rx drained count=");
            bootTraceHex(count);
            bootTrace(" lsr=");
            bootTraceHex(uart.lineStatus());
            bootTrace(" iir=");
            bootTraceHex(uart.interruptStatus());
            bootTrace("\n");
        }

        // Wake up all processes sleeping on serial input channel
        // We need to hold the proc lock when waking up processes
        // In interrupt context, pushoff() in acquire() will just
        // increment the interrupt disable count, which is safe
        bootTrace("U: before wakeup\n");
        task.proc.wakeup(@intCast(@intFromPtr(&input_buffer)));
        bootTrace("U: after wakeup\n");
        bootTrace("U: before release\n");
        input_buffer.console_lock.release();
        bootTrace("U: after release\n");
    }

    pub fn enableUartPlic() void {
        const cpu = 0;

        plic.registerIrq(board_cfg.uart0.irq, &Serial.handleUartIrq);
        plic.plicEnableIrq(cpu, board_cfg.uart0.irq, true);
        uart.enableInterrupt();
    }
};

// ------------------- Serial Device Implementation -------------------

// Serial device private data (we don't need any for now)
const SerialDevice = struct {};

// Serial device instance
var serial_dev_instance = SerialDevice{};

// Serial device read operation
fn serialRead(_: *anyopaque, buffer: []u8, _: usize) anyerror!usize {
    var bytes_read: usize = 0;

    input_buffer.console_lock.acquire();
    defer input_buffer.console_lock.release();

    // Block until at least one character is available
    while (bytes_read == 0) {
        // Check if there's any data
        if (Serial.uartGet()) |c| {
            buffer[bytes_read] = c;
            bytes_read += 1;

            // Read more if available (non-blocking for additional bytes)
            for (buffer[bytes_read..]) |*b| {
                if (Serial.uartGet()) |next_c| {
                    b.* = next_c;
                    bytes_read += 1;
                } else {
                    break; // No more data
                }
            }
        } else {
            // No data available - sleep
            // sleep will release the lock temporarily and reacquire it upon wakeup
            task.proc.sleep(@intCast(@intFromPtr(&input_buffer)), &input_buffer.console_lock);
        }
    }

    return bytes_read;
}

// Serial device write operation
var serial_write_lock: SpinLock = SpinLock.init("serial_write");

/// Serialize complete console writes with kernel log records.
pub fn lockOutput() void {
    serial_write_lock.acquire();
}

pub fn unlockOutput() void {
    serial_write_lock.release();
}

fn writeOutput(buffer: []const u8) void {
    lockOutput();
    defer unlockOutput();
    Serial.write(buffer);
}

fn serialWrite(_: *anyopaque, buffer: []const u8, _: usize) anyerror!usize {
    writeOutput(buffer);
    return buffer.len;
}

// Public serial device export
pub const serial_device = @import("device").Device {
    .num = .{
        .major = 1,
        .minor = 0,
    },
    .dev_type = @import("device").Kind.Char,
    .name = "serial",
    .ctx = &serial_dev_instance,

    // Serial device operations
    .ops = .{
        .Char = .{
            .read = &serialRead,
            .write = &serialWrite,
        },
    },
};

const console_backend = utils.ConsoleBackend {
    .write = &Serial.write,
    .now = &riscv.readTime,
    .cpuId = &riscv.readHart,
    .atLineStart = &Serial.atLineStart,
    .lockOutput = &lockOutput,
    .unlockOutput = &unlockOutput,
};

pub fn init() void {
    utils.installConsole(console_backend);
}
