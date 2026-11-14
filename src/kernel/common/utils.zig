const std = @import("std");
const board_cfg = @import("board").config;

pub const ConsoleBackend = struct {
    write: *const fn ([]const u8) void,
    now: *const fn () u64, // retrieve time
    cpuId: *const fn () usize, // retrieve cpu cor
    atLineStart: *const fn () bool,
    lockOutput: *const fn () void,
    unlockOutput: *const fn () void,
};

var console_backend: ?ConsoleBackend = null;

pub fn installConsole(backend: ConsoleBackend) void {
    console_backend = backend;
}

fn out() ConsoleBackend {
    return console_backend orelse @panic("console backend not installed");
}

const TIMEBASE_HZ: u64 = board_cfg.timer.freq;
var first_log_time: ?u64 = null;
var log_line_start = true;
var log_line_hart: usize = 0;

fn logPrefix(hart: usize) void {
    if (!out().atLineStart()) out().write("\n");
    const now = out().now();
    if (first_log_time == null) first_log_time = now;
    const elapsed = now -% first_log_time.?;
    const seconds = elapsed / TIMEBASE_HZ;
    var microseconds = (elapsed % TIMEBASE_HZ) / (TIMEBASE_HZ / 1_000_000);
    var scratch: [32]u8 = undefined;
    const seconds_text = formatDecUnsigned(seconds, &scratch);

    out().write("[");
    for (seconds_text.len..5) |_| out().write(" ");
    out().write(seconds_text);
    out().write(".");
    var fraction: [6]u8 = undefined;
    for (0..fraction.len) |i| {
        fraction[fraction.len - 1 - i] = @as(u8, @intCast(microseconds % 10)) + '0';
        microseconds /= 10;
    }
    out().write(&fraction);
    out().write("] <");
    out().write(formatDecUnsigned(hart, &scratch));
    out().write("> ");
    log_line_hart = hart;
    log_line_start = false;
}

fn logWrite(hart: usize, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        if (log_line_start) logPrefix(hart);
        const rest = data[offset..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            out().write(rest[0 .. newline + 1]);
            offset += newline + 1;
            log_line_start = true;
        } else {
            out().write(rest);
            break;
        }
    }
}

// this way is also useful to get a symbol and @intFromPtr(&func)
// but maybe need @constCast
// extern fn stext_boot() noreturn;
// extern fn etext_boot() noreturn;

pub extern const stext_boot: u8;
pub extern const etext_boot: u8;
pub extern const stext: u8;
pub extern const etext: u8;
pub extern const srodata: u8;
pub extern const erodata: u8;
pub extern const sdata: u8;
pub extern const edata: u8;
pub extern var sbss: u8;
pub extern var ebss: u8;
pub extern const skernel: u8;
pub extern const ekernel: u8;

pub fn kprint(comptime fmt: []const u8, args: anytype) void {
    out().lockOutput();
    defer out().unlockOutput();

    const hart = out().cpuId();
    // A partial line from another hart must not claim this hart's output.
    if (!log_line_start and log_line_hart != hart) {
        out().write("\n");
        log_line_start = true;
    }
    var scratch: [32]u8 = undefined;

    var arg_idx: usize = 0;
    var i: usize = 0;
    var last_pos: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i > last_pos) {
                logWrite(hart, fmt[last_pos..i]);
            }

            var j = i + 1;
            while (j < fmt.len and fmt[j] != '}') : (j += 1) {}

            if (j < fmt.len) {
                const spec = fmt[i + 1 .. j];

                if (arg_idx < args.len) {
                    inline for (args, 0..) |arg, idx| {
                        if (idx == arg_idx) {
                            formatArg(hart, arg, spec, &scratch);
                        }
                    }
                    arg_idx += 1;
                }

                i = j + 1;
                last_pos = i;
                continue;
            }
        }
        i += 1;
    }

    if (last_pos < fmt.len) {
        logWrite(hart, fmt[last_pos..]);
    }
}

fn formatArg(hart: usize, arg: anytype, spec: []const u8, scratch: []u8) void {
    const T = @TypeOf(arg);
    const type_name = @typeName(T);

    // check（u8, u16, u32, u64, usize, i8, i16, i32, i64, isize）
    if (comptime isInteger(T)) {
        formatInteger(hart, arg, spec, scratch);
        return;
    }

    // check is string
    if (T == []const u8 or T == []u8) {
        logWrite(hart, arg);
        return;
    }

    // check is bool
    if (T == bool) {
        logWrite(hart, if (arg) "true" else "false");
        return;
    }

    // check is error
    if (comptime isError(T)) {
        logWrite(hart, "error.");
        logWrite(hart, @errorName(arg));
        return;
    }

    // check is pointer（type_name include "*"）
    if (comptime std.mem.indexOf(u8, type_name, "*") != null) {
        const s = formatHex(@intFromPtr(arg), scratch);
        logWrite(hart, "0x");
        logWrite(hart, s);
        return;
    }

    // unknow type
    logWrite(hart, "(?)");
}

fn isError(comptime T: type) bool {
    return @typeInfo(T) == .error_set;
}

// comptime check is Integer
fn isInteger(comptime T: type) bool {
    return T == u8 or T == u16 or T == u32 or T == u64 or T == usize or T == u128 or
        T == i8 or T == i16 or T == i32 or T == i64 or T == isize or T == i128 or
        T == comptime_int;
}

fn formatInteger(hart: usize, arg: anytype, spec: []const u8, scratch: []u8) void {
    const T = @TypeOf(arg);

    // check is unsigned
    const is_signed = (T == i8 or T == i16 or T == i32 or T == i64 or T == isize or T == i128);

    if (spec.len > 0) {
        if (std.mem.eql(u8, spec, "x")) {
            const val = @as(usize, @intCast(@abs(@as(i128, arg))));
            const s = formatHex(val, scratch);
            logWrite(hart, s);
            return;
        } else if (std.mem.eql(u8, spec, "d")) {
            const s = formatDec(@as(i64, @intCast(arg)), scratch);
            logWrite(hart, s);
            return;
        } else if (std.mem.eql(u8, spec, "u")) {
            const s = formatDecUnsigned(@as(u64, @intCast(arg)), scratch);
            logWrite(hart, s);
            return;
        }
    }

    // default format
    if (is_signed) {
        const s = formatDec(@as(i64, @intCast(arg)), scratch);
        logWrite(hart, s);
    } else {
        const s = formatDecUnsigned(@as(u64, @intCast(arg)), scratch);
        logWrite(hart, s);
    }
}

fn formatHex(val: usize, buf: []u8) []u8 {
    const hex_chars = "0123456789abcdef";

    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var shift: u6 = 60;
    while (shift > 0) : (shift -= 4) {
        if ((val >> shift) & 0xF != 0) break;
    }

    var i: usize = 0;
    while (true) {
        const nibble = @as(u8, @truncate((val >> shift) & 0xF));
        buf[i] = hex_chars[nibble];
        i += 1;

        if (shift == 0) break;
        shift -= 4;
    }

    return buf[0..i];
}

fn formatDec(val: i64, buf: []u8) []u8 {
    if (val < 0) {
        buf[0] = '-';
        const rest = formatDecUnsigned(@as(u64, @intCast(-val)), buf[1..]);
        return buf[0 .. rest.len + 1];
    } else {
        return formatDecUnsigned(@as(u64, @intCast(val)), buf);
    }
}

fn formatDecUnsigned(val: u64, buf: []u8) []u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var temp: [20]u8 = undefined;
    var i: usize = 0;
    var n = val;

    while (n > 0) {
        temp[i] = @as(u8, @intCast((n % 10) + '0'));
        n /= 10;
        i += 1;
    }

    var j: usize = 0;
    while (i > 0) {
        i -= 1;
        buf[j] = temp[i];
        j += 1;
    }

    return buf[0..j];
}

pub fn displayMem() void {
    const _stext_boot = @as(u64, @intFromPtr(&stext_boot));
    const _etext_boot = @as(u64, @intFromPtr(&etext_boot));
    const _stext = @as(u64, @intFromPtr(&stext));
    const _etext = @as(u64, @intFromPtr(&etext));
    const _srodata = @as(u64, @intFromPtr(&srodata));
    const _erodata = @as(u64, @intFromPtr(&erodata));
    const _sdata = @as(u64, @intFromPtr(&sdata));
    const _edata = @as(u64, @intFromPtr(&edata));
    const _sbss = @as(u64, @intFromPtr(&sbss));
    const _ebss = @as(u64, @intFromPtr(&ebss));
    const _skernel = @as(u64, @intFromPtr(&skernel));
    const _ekernel = @as(u64, @intFromPtr(&ekernel));

    kprint("------- image mem space info -------\n", .{});
    kprint(".text.boot mem info : 0x{x} - 0x{x} ({} B)\n", .{ _stext_boot, _etext_boot, _etext_boot - _stext_boot });
    kprint("     .text mem info : 0x{x} - 0x{x} ({} B)\n", .{ _stext, _etext, _etext - _stext });
    kprint("   .rodata mem info : 0x{x} - 0x{x} ({} B)\n", .{ _srodata, _erodata, _erodata - _srodata });
    kprint("     .data mem info : 0x{x} - 0x{x} ({} B)\n", .{ _sdata, _edata, _edata - _sdata });
    kprint("      .bss mem info : 0x{x} - 0x{x} ({} B)\n", .{ _sbss, _ebss, _ebss - _sbss });
    kprint("   .kernel mem info : 0x{x} - 0x{x} ({} B)\n", .{ _skernel, _ekernel, _ekernel - _skernel });
    kprint("------- image mem space info over -------\n", .{});
}
