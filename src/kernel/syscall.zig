const std = @import("std");

const arch = @import("arch");
const riscv = arch.riscv;
const sbi = arch.sbi;

const boot_trace = @import("board").config.boot_trace;

const task = @import("task.zig");
const memory = @import("memory.zig");
const proc = @import("task.zig").proc;
const vfs = @import("fs").vfs;

const common = @import("common");
const utils = common.utils;
const address = common.address;

const PhysicalAddress = address.PhysicalAddress;
const VirtAddress = address.VirtAddress;
const Page = address.Page;

const USER_BUFFER_SIZE = address.USER_BUFFER_SIZE;
const PAGE_SIZE = address.PAGE_SIZE;

const trapFrame = @import("trap.zig").trapFrame;

const ticks_lock = &@import("timer.zig").ticks_lock;

const kprint = @import("common").utils.kprint;

fn bootTrace(comptime message: []const u8) void {
    if (comptime boot_trace) {
        for (message) |c| {
            if (c == '\n') sbi.putChar('\r');
            sbi.putChar(c);
        }
    }
}

fn bootTraceSlice(message: []const u8) void {
    if (comptime boot_trace) {
        for (message) |c| {
            if (c == '\n') sbi.putChar('\r');
            sbi.putChar(c);
        }
    }
}

fn bootTraceHex(value: u64) void {
    if (comptime boot_trace) {
        sbi.putChar('0');
        sbi.putChar('x');

        var shift: u6 = 60;
        while (true) {
            const nibble: u8 = @truncate((value >> shift) & 0xf);
            sbi.putChar(if (nibble < 10) '0' + nibble else 'a' + nibble - 10);
            if (shift == 0) break;
            shift -= 4;
        }
    }
}

const SYS_fork = 1;
const SYS_exit = 2;
const SYS_wait = 3;
const SYS_pipe = 4;
const SYS_read = 5;
const SYS_kill = 6;
const SYS_exec = 7;
const SYS_fstat = 8;
const SYS_chdir = 9;
const SYS_dup = 10;
const SYS_getpid = 11;
const SYS_sbrk = 12;
const SYS_sleep = 13;
const SYS_uptime = 14;
const SYS_open = 15;
const SYS_write = 16;
const SYS_mknod = 17;
const SYS_unlink = 18;
const SYS_link = 19;
const SYS_mkdir = 20;
const SYS_close = 21;
const SYS_console = 22;
const SYS_readdir = 23;
const SYS_getcwd = 24;
const SYS_getcpu = 25;

// Dedicated ABI result for syscall numbers without a handler (ENOSYS).
const SYS_ERR_NOT_IMPLEMENTED: i64 = -38;

pub const MAXPATH = 64;
pub const MAXARG = 16;

fn argraw(n: i32) !u64 {
    const t = task.TaskCpu.currentTcb().?;

    const trapframe = t.trapframe;

    // riscv spec: a0 ~ a7 is arguments
    return switch (n) {
        0 => trapframe.a0,
        1 => trapframe.a1,
        2 => trapframe.a2,
        3 => trapframe.a3,
        4 => trapframe.a4,
        5 => trapframe.a5,
        else => @panic("invalid argument\n"),
    };
}

fn argint(n: i32, ip: *i32) !void {
    ip.* = @intCast(try argraw(n));
}

// retrieve string from user space
pub fn fetchstr(uaddr: u64, buf: []u8) !u64 {
    const p = task.TaskCpu.currentTcb().?;

    if (uaddr > p.sz or uaddr + 8 > p.sz) {
        utils.kprint("fetchstr: wrong uaddr {}\n", .{uaddr});
        return error.InvalidAddress;
    }

    return p.pagetable.copyInStr(buf, VirtAddress{ .addr = uaddr });
}

// retrieve uin64 at addr from current process user space
pub fn fetchaddr(uaddr: u64) !u64 {
    const t = task.TaskCpu.currentTcb().?;

    if (uaddr > t.sz or uaddr + 8 > t.sz) {
        utils.kprint("fetchstr: wrong uaddr {}\n", .{uaddr});
        return error.InvalidAddress;
    }

    var addr: u64 = undefined;
    const buf = @as([*]u8, @ptrCast(@alignCast(&addr)))[0..@sizeOf(u64)];

    if (!t.pagetable.copyIn(buf, VirtAddress.init(uaddr), buf.len)) {
        return error.InvalidAddress;
    }

    return addr;
}

// retrieve syscall argument (address)
pub fn argaddr(n: i32) !u64 {
    return argraw(n);
}

// retrieve syscall argument (string)
pub fn argstr(n: i32, buf: []u8) !u64 {
    const uaddr = try argaddr(n);

    return fetchstr(uaddr, buf);
}

fn cleanupArgv(buffers: []?ArgBuffer) void {
    for (buffers) |buf_opt| {
        if (buf_opt) |buf| {
            buf.deinit(PAGE_SIZE);
        }
    }
}

const ArgBuffer = struct {
    ptr: *u8,
    len: usize,

    pub fn fromKalloc(size: usize) ?ArgBuffer {
        const ptr = memory.kalloc(u8, size) catch |err| {
            kprint("alloc failed: {}\n", .{err});
            return null;
        };
        return ArgBuffer{
            .ptr = ptr,
            .len = 0,
        };
    }

    pub fn deinit(self: ArgBuffer, size: usize) void {
        memory.kfree(u8, self.ptr, size);
    }

    pub fn asSlice(self: ArgBuffer) []u8 {
        return @as([*]u8, @ptrCast(self.ptr))[0..self.len];
    }
};

fn sysExec() u64 {
    bootTrace("T: sysExec enter\n");
    var path: [MAXPATH]u8 = undefined;
    var uarg_buffers: [MAXARG]?ArgBuffer = @splat(null);
    var uargc: usize = 0;

    const path_len = argstr(0, path[0..MAXPATH]) catch {
        bootTrace("T: sysExec path failed\n");
        return @bitCast(@as(i64, -1));
    };
    if (comptime boot_trace) {
        bootTrace("T: sysExec path=");
        bootTraceSlice(path[0..path_len]);
        bootTrace(" len=");
        bootTraceHex(path_len);
        bootTrace("\n");
    }

    const path_slice = path[0..path_len];

    const uargv = argaddr(1) catch {
        bootTrace("T: sysExec argv address failed\n");
        return @bitCast(@as(i64, -1));
    };
    if (comptime boot_trace) {
        bootTrace("T: sysExec uargv=");
        bootTraceHex(uargv);
        bootTrace("\n");
    }

    var i: usize = 0;
    while (i < MAXARG) : (i += 1) {
        const uarg = fetchaddr(uargv + i * @sizeOf(u64)) catch |err| {
            if (err == error.InvalidAddress) break;
            cleanupArgv(&uarg_buffers);
            return @bitCast(@as(i64, -1));
        };

        if (uarg == 0) break; // NULL

        var buf = ArgBuffer.fromKalloc(PAGE_SIZE) orelse {
            cleanupArgv(&uarg_buffers);
            return @bitCast(@as(i64, -1));
        };

        const buf_slice = @as([*]u8, @ptrCast(buf.ptr))[0..PAGE_SIZE];

        buf.len = fetchstr(uarg, buf_slice) catch {
            buf.deinit(PAGE_SIZE);
            cleanupArgv(&uarg_buffers);
            return @bitCast(@as(i64, -1));
        };

        uarg_buffers[i] = buf;
        uargc += 1;
    }
    if (comptime boot_trace) {
        bootTrace("T: sysExec argc=");
        bootTraceHex(uargc);
        bootTrace("\n");
    }

    var argv: [MAXARG][]u8 = undefined;
    for (uarg_buffers[0..uargc], 0..) |buf_opt, idx| {
        argv[idx] = buf_opt.?.asSlice();
    }

    const ret = proc.exec(path_slice, argv[0..uargc]);
    if (comptime boot_trace) {
        bootTrace("T: sysExec proc.exec returned=");
        bootTraceHex(ret);
        bootTrace("\n");
    }

    cleanupArgv(&uarg_buffers);
    bootTrace("T: sysExec leave\n");
    return ret;
}

fn sysOpen() u64 {
    const t = task.TaskCpu.currentTcb().?;

    var path: [MAXPATH]u8 = undefined;
    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    const flags: u32 = @intCast(argraw(1) catch {
        return @bitCast(@as(i64, -1));
    });

    return t.fileOpen(path_slice, flags) catch @bitCast(@as(i64, -1));
}

fn sysExit() u64 {
    const xstate = argraw(0) catch {
        return @bitCast(@as(u64, -1));
    };
    proc.exit(@intCast(xstate));

    return 0;
}

fn sysRead() u64 {
    const t = task.TaskCpu.currentTcb().?;

    const fd = argraw(0) catch {
        return @bitCast(@as(i64, -1));
    };

    const uaddr = argraw(1) catch {
        return @bitCast(@as(i64, -1));
    };

    const count = argraw(2) catch {
        return @bitCast(@as(i64, -1));
    };

    // Read from user space buffer
    var kernel_buf: [USER_BUFFER_SIZE]u8 = undefined;
    var total: usize = 0;

    while (total < count) {
        const chunk = @min(count - total, USER_BUFFER_SIZE);

        const bytes_read = t.fileRead(@intCast(fd), kernel_buf[0..chunk]) catch |err| {
            if (total > 0) return total;
            kprint("sys: fileRead failed err: {}\n", .{err});
            return @bitCast(@as(i64, -1));
        };

        if (bytes_read == 0) break;

        // Write data back to user space
        if (t.pagetable.copyOut(VirtAddress.init(uaddr + total), kernel_buf[0..bytes_read], bytes_read) == false) {
            if (total > 0) return total;
            return @bitCast(@as(i64, -1));
        }

        total += bytes_read;

        if (bytes_read < chunk) break;
    }

    return total;
}

fn sysKill() u64 {
    const pid = argraw(0) catch {
        return @bitCast(@as(u64, -1));
    };

    proc.kill(@intCast(pid));

    return 0;
}

fn sysWrite() u64 {
    const t = task.TaskCpu.currentTcb().?;

    const fd = argraw(0) catch {
        return @bitCast(@as(i64, -1));
    };

    const uaddr = argraw(1) catch {
        return @bitCast(@as(i64, -1));
    };

    const count = argraw(2) catch {
        return @bitCast(@as(i64, -1));
    };

    // Read data from user space
    var kernel_buf: [USER_BUFFER_SIZE]u8 = undefined;
    var total_written: usize = 0;

    while (total_written < count) {
        const chunk_size = @min(count - total_written, USER_BUFFER_SIZE);

        if (t.pagetable.copyIn(kernel_buf[0..chunk_size], VirtAddress.init(uaddr + total_written), chunk_size) == false) {
            if (total_written > 0) return total_written;
            return @bitCast(@as(i64, -1));
        }

        const bytes_written = t.fileWrite(@intCast(fd), kernel_buf[0..chunk_size]) catch {
            if (total_written > 0) return total_written;
            return @bitCast(@as(i64, -1));
        };
        total_written += bytes_written;

        if (bytes_written < chunk_size) break;
    }
    return total_written;
}

fn sysClose() u64 {
    const t = task.TaskCpu.currentTcb().?;

    const fd = argraw(0) catch {
        return @bitCast(@as(i64, -1));
    };

    t.fileClose(@intCast(fd)) catch {
        return @bitCast(@as(i64, -1));
    };

    return 0;
}

fn sysUnlink() u64 {
    var path: [MAXPATH]u8 = undefined;

    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    vfs.get_vfs().remove(path_slice) catch {
        return @bitCast(@as(i64, -1));
    };

    return 0;
}

fn sysMknod() u64 {
    var path: [MAXPATH]u8 = undefined;

    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    const mode: u32 = @intCast(argraw(1) catch {
        return @bitCast(@as(i64, -1));
    });

    const dev: u32 = @intCast(argraw(2) catch {
        return @bitCast(@as(i64, -1));
    });

    vfs.get_vfs().mknod(path_slice, mode, dev) catch {
        return @bitCast(@as(i64, -1));
    };

    return 0;
}

fn sysMkdir() u64 {
    var path: [MAXPATH]u8 = undefined;

    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    // mode is passed but vfs.mkdir uses 0o755 internally
    _ = argraw(1) catch {};

    vfs.get_vfs().mkdir(path_slice) catch |err| {
        kprint("sysMkdir: mkdir failed: {}\n", .{err});
        return @bitCast(@as(i64, -1));
    };

    return 0;
}

fn sysConsole() u64 {
    const t = task.TaskCpu.currentTcb().?;

    const fd = t.trapframe.a0;
    const buf_va = t.trapframe.a1;
    const count = t.trapframe.a2;
    if (fd != 1 and fd != 2) {
        return @bitCast(@as(i64, -1));
    }

    var kernel_buf: [USER_BUFFER_SIZE]u8 = undefined;
    const actual_count = @min(count, kernel_buf.len);

    if (t.pagetable.copyIn(&kernel_buf, VirtAddress.init(buf_va), actual_count) == false) {
        return @bitCast(@as(i64, -1));
    }

    kprint("{}", .{kernel_buf[0..actual_count]});

    return actual_count;
}

fn sysGetpid() u64 {
    const t = task.TaskCpu.currentTcb().?;

    return t.pid;
}

fn sysSleep() u64 {
    var n: i32 = 0;
    argint(0, &n) catch {
        return @bitCast(@as(i64, -1));
    };
    if (n < 0)
        n = 0;

    const timer = @import("timer.zig");
    const ticks0 = timer.jiffies.get();

    ticks_lock.acquire();

    while (timer.jiffies.get() - ticks0 < @as(u64, @intCast(n))) {
        const t = task.TaskCpu.currentTcb().?;
        if (t.isKilled()) {
            ticks_lock.release();
            return @bitCast(@as(i64, -1));
        }
        proc.sleep(@intCast(@intFromPtr(&timer.jiffies)), ticks_lock);
    }

    ticks_lock.release();
    return 0;
}

fn sysReaddir() u64 {
    var path: [MAXPATH]u8 = undefined;

    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    const ubuf = argaddr(1) catch {
        return @bitCast(@as(i64, -1));
    };
    const ubuf_size = argraw(2) catch {
        return @bitCast(@as(i64, -1));
    };

    const entries = vfs.get_vfs().readdir(path_slice) catch |err| {
        kprint("sysReaddir: failed to read dir {s}: {}\n", .{ path_slice, err });
        return @bitCast(@as(i64, -1));
    };
    defer vfs.get_vfs().allocator.free(entries);

    // Serialize the entries
    const t = task.TaskCpu.currentTcb().?;

    // Allocate kernel buffer for serialization - ensure 8-byte alignment
    var kernel_buf_unaligned: [USER_BUFFER_SIZE + 8]u8 = undefined;
    const buf_addr = @intFromPtr(&kernel_buf_unaligned);
    const aligned_addr = (buf_addr + 7) & ~@as(usize, 7);
    const kernel_buf = @as([*]u8, @ptrFromInt(aligned_addr))[0..USER_BUFFER_SIZE];

    var offset: usize = 0;

    // Write number of entries using unaligned write
    std.mem.writeInt(u32, kernel_buf[offset..][0..4], @intCast(entries.len), .little);
    offset += @sizeOf(u32);

    for (entries) |entry| {
        // Write file type
        std.mem.writeInt(u32, kernel_buf[offset..][0..4], @backingInt(entry.file_type), .little);
        offset += @sizeOf(u32);

        // Write inode ID
        std.mem.writeInt(u64, kernel_buf[offset..][0..8], entry.inode_id, .little);
        offset += @sizeOf(u64);

        // Write string length
        std.mem.writeInt(u32, kernel_buf[offset..][0..4], @intCast(entry.name.len), .little);
        offset += @sizeOf(u32);

        // Write string bytes
        @memcpy(kernel_buf[offset .. offset + entry.name.len], entry.name);
        offset += entry.name.len;

        // Add padding to align to 8 bytes for next entry
        const padding = (8 - (offset % 8)) % 8;
        offset += padding;
    }

    const bytes_to_copy = @min(ubuf_size, offset);

    if (bytes_to_copy < @sizeOf(u32)) {
        return @bitCast(@as(i64, -1));
    }

    if (t.pagetable.copyOut(VirtAddress.init(ubuf), kernel_buf[0..bytes_to_copy], bytes_to_copy) == false) {
        return @bitCast(@as(i64, -1));
    }

    return bytes_to_copy;
}

fn sysFork() u64 {
    return task.proc.fork();
}

fn sysWait() u64 {
    var addr: u64 = 0;
    addr = argaddr(0) catch {
        return @bitCast(@as(i64, -1));
    };

    return task.proc.wait(addr);
}

fn sysChdir() u64 {
    const t = task.TaskCpu.currentTcb().?;

    var path: [MAXPATH]u8 = undefined;
    const path_len = argstr(0, path[0..MAXPATH]) catch {
        return @bitCast(@as(i64, -1));
    };
    const path_slice = path[0..path_len];

    // Lookup the target directory
    const new_cwd = vfs.get_vfs().path_lookup(path_slice, false, t.cwd) catch |err| {
        kprint("sysChdir: path_lookup failed: {}\n", .{err});
        return @bitCast(@as(i64, -1));
    };

    if (new_cwd == null) {
        return @bitCast(@as(i64, -1));
    }

    // Check if it's a directory
    if (new_cwd.?.inode.file_type != .Directory) {
        return @bitCast(@as(i64, -1));
    }

    // Release old CWD reference
    if (t.cwd) |old_cwd| {
        old_cwd.ref_count -= 1;
    }

    // Set new CWD and increment reference count
    t.cwd = new_cwd;
    t.cwd.?.ref_count += 1;

    return 0;
}

fn sysGetcwd() u64 {
    const t = task.TaskCpu.currentTcb().?;

    const ubuf = argaddr(0) catch {
        return @bitCast(@as(i64, -1));
    };
    const ubuf_size = argraw(1) catch {
        return @bitCast(@as(i64, -1));
    };

    if (t.cwd == null) {
        return @bitCast(@as(i64, -1));
    }

    // Build path by traversing parent pointers
    var path_components: [16][]const u8 = undefined;
    var component_count: usize = 0;

    var current = t.cwd;
    while (current) |d| {
        if (component_count >= 16) break;
        path_components[component_count] = d.name;
        component_count += 1;
        current = d.parent;
    }

    // Build the path string in reverse order
    var kernel_buf: [MAXPATH]u8 = undefined;
    var offset: usize = 0;

    // Add leading slash
    if (offset < kernel_buf.len) {
        kernel_buf[offset] = '/';
        offset += 1;
    }

    // Add components in reverse (from root to current)
    var i: usize = component_count;
    while (i > 0) : (i -= 1) {
        const comp = path_components[i - 1];
        if (std.mem.eql(u8, comp, "/")) continue; // Skip root component

        if (offset + comp.len + 1 > kernel_buf.len) break;

        @memcpy(kernel_buf[offset..][0..comp.len], comp);
        offset += comp.len;

        // Add separator if not the last component
        if (i > 1) {
            kernel_buf[offset] = '/';
            offset += 1;
        }
    }

    // Null terminate
    if (offset < kernel_buf.len) {
        kernel_buf[offset] = 0;
        offset += 1;
    }

    // Copy to user space
    const bytes_to_copy = @min(ubuf_size, offset);
    if (t.pagetable.copyOut(VirtAddress.init(ubuf), kernel_buf[0..offset], bytes_to_copy) == false) {
        return @bitCast(@as(i64, -1));
    }

    return ubuf;
}

pub fn trapSyscallHandler(trapframe: *trapFrame) void {
    const syscall_num = trapframe.a7;

    switch (syscall_num) {
        SYS_fork => {
            trapframe.a0 = sysFork();
        },
        SYS_exit => {
            trapframe.a0 = sysExit();
        },
        SYS_wait => {
            trapframe.a0 = sysWait();
        },
        SYS_exec => {
            trapframe.a0 = sysExec();
        },
        SYS_open => {
            trapframe.a0 = sysOpen();
        },
        SYS_getpid => {
            trapframe.a0 = sysGetpid();
        },
        SYS_getcpu => {
            trapframe.a0 = riscv.riscvReadTp();
        },
        SYS_sleep => {
            trapframe.a0 = sysSleep();
        },
        SYS_read => {
            trapframe.a0 = sysRead();
        },
        SYS_kill => {
            trapframe.a0 = sysKill();
        },
        SYS_write => {
            trapframe.a0 = sysWrite();
        },
        SYS_close => {
            trapframe.a0 = sysClose();
        },
        SYS_unlink => {
            trapframe.a0 = sysUnlink();
        },
        SYS_mknod => {
            trapframe.a0 = sysMknod();
        },
        SYS_mkdir => {
            trapframe.a0 = sysMkdir();
        },
        SYS_console => {
            trapframe.a0 = sysConsole();
        },
        SYS_readdir => {
            trapframe.a0 = sysReaddir();
        },
        SYS_chdir => {
            trapframe.a0 = sysChdir();
        },
        SYS_getcwd => {
            trapframe.a0 = sysGetcwd();
        },
        else => {
            kprint("Unsupported Syscall num: {}\n", .{syscall_num});
            trapframe.a0 = @bitCast(SYS_ERR_NOT_IMPLEMENTED);
        },
    }
}
