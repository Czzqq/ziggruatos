const utils = @import("common").utils;
const address = @import("common").address;

const arch = @import("arch");
const io = arch.io;
const riscv = arch.riscv;

const boot_trace = @import("board").config.boot_trace;

const drivers = @import("drivers");
const plic = drivers.plic;

const timer = @import("timer.zig");
const task = @import("task.zig");
const proc = @import("task.zig").proc;
const syscall = @import("syscall.zig");

fn bootTrace(comptime message: []const u8) void {
    if (comptime boot_trace) {
        for (message) |c| {
            if (c == '\n') drivers.uart.put('\r');
            drivers.uart.put(c);
        }
    }
}

fn bootTraceHex(value: u64) void {
    if (comptime boot_trace) {
        drivers.uart.put('0');
        drivers.uart.put('x');

        var shift: u6 = 60;
        while (true) {
            const nibble: u8 = @truncate((value >> shift) & 0xf);
            drivers.uart.put(if (nibble < 10) '0' + nibble else 'a' + nibble - 10);
            if (shift == 0) break;
            shift -= 4;
        }
    }
}

const TRAMPOLINE: usize = address.TRAMPOLINE;
const PAGE_SIZE: usize = address.PAGE_SIZE;

pub const trapFrame = struct {
    kernel_satp: u64, // 0  kernel page table
    kernel_sp: u64, // 8  top of process's kernel stack
    kernel_trap: u64, // 16 kernel trap process func()
    kernel_hartid: u64, // 24 current 'hart' id

    sepc: u64, // 32 epc

    // generic regs
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    s0: u64,
    s1: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
    // Superivsor CSRs
    sstatus: u64,
    sbadaddr: u64,
    scause: u64,
    // a0 value before syscall
    orig_a0: u64,
};

pub const PT = struct {
    pub const SIZE = @sizeOf(trapFrame);

    pub const KERNEL_SATP = @offsetOf(trapFrame, "kernel_satp");
    pub const KERNEL_SP = @offsetOf(trapFrame, "kernel_sp");
    pub const KERNEL_TRAP = @offsetOf(trapFrame, "kernel_trap");
    pub const KERNEL_HARTID = @offsetOf(trapFrame, "kernel_hartid");

    pub const SEPC = @offsetOf(trapFrame, "sepc");
    pub const RA = @offsetOf(trapFrame, "ra");
    pub const SP = @offsetOf(trapFrame, "sp");
    pub const GP = @offsetOf(trapFrame, "gp");
    pub const TP = @offsetOf(trapFrame, "tp");
    pub const T0 = @offsetOf(trapFrame, "t0");
    pub const T1 = @offsetOf(trapFrame, "t1");
    pub const T2 = @offsetOf(trapFrame, "t2");
    pub const S0 = @offsetOf(trapFrame, "s0");
    pub const S1 = @offsetOf(trapFrame, "s1");
    pub const A0 = @offsetOf(trapFrame, "a0");
    pub const A1 = @offsetOf(trapFrame, "a1");
    pub const A2 = @offsetOf(trapFrame, "a2");
    pub const A3 = @offsetOf(trapFrame, "a3");
    pub const A4 = @offsetOf(trapFrame, "a4");
    pub const A5 = @offsetOf(trapFrame, "a5");
    pub const A6 = @offsetOf(trapFrame, "a6");
    pub const A7 = @offsetOf(trapFrame, "a7");
    pub const S2 = @offsetOf(trapFrame, "s2");
    pub const S3 = @offsetOf(trapFrame, "s3");
    pub const S4 = @offsetOf(trapFrame, "s4");
    pub const S5 = @offsetOf(trapFrame, "s5");
    pub const S6 = @offsetOf(trapFrame, "s6");
    pub const S7 = @offsetOf(trapFrame, "s7");
    pub const S8 = @offsetOf(trapFrame, "s8");
    pub const S9 = @offsetOf(trapFrame, "s9");
    pub const S10 = @offsetOf(trapFrame, "s10");
    pub const S11 = @offsetOf(trapFrame, "s11");
    pub const T3 = @offsetOf(trapFrame, "t3");
    pub const T4 = @offsetOf(trapFrame, "t4");
    pub const T5 = @offsetOf(trapFrame, "t5");
    pub const T6 = @offsetOf(trapFrame, "t6");
    // Superivsor CSRs
    pub const SSTATUS = @offsetOf(trapFrame, "sstatus");
    pub const SBADADDR = @offsetOf(trapFrame, "sbadaddr");
    pub const SCACUSE = @offsetOf(trapFrame, "scause");
    // a0 value before syscall
    pub const ORIG_A0 = @offsetOf(trapFrame, "orig_a0");
};

const FaultInfo = struct {
    fn_ptr: *const fn (regs: *trapFrame, msg: []const u8) u32,
    msg: []const u8,
};

const SCAUSE_EC: usize = 0xf;
const SCAUSE_INT: usize = 0x1 << 63;

/// interrupts
const INTERRUPT_CAUSE_SOFTWARE: usize = 0x1;
const INTERRUPT_CAUSE_TIMER: usize = 0x5;
const INTERRUPT_CAUSE_EXTERNAL: usize = 0x9;

/// exception
const EXC_SYSCALL: usize = 0x8;

fn show_regs(regs: *trapFrame) void {
    utils.kprint("sepc: 0x{x} ra: 0x{x} sp : 0x{x}\n", .{ regs.sepc, regs.ra, regs.sp });
    utils.kprint(" gp : 0x{x} tp: 0x{x} t0 : 0x{x}\n", .{ regs.gp, regs.tp, regs.t0 });
    utils.kprint(" t1 : 0x{x} t2: 0x{x} t3 : 0x{x}\n", .{ regs.t1, regs.t2, regs.s0 });
    utils.kprint(" s1 : 0x{x} a0: 0x{x} a1 : 0x{x}\n", .{ regs.s1, regs.a0, regs.a1 });
    utils.kprint(" a2 : 0x{x} a3: 0x{x} a4 : 0x{x}\n", .{ regs.a2, regs.a3, regs.a4 });
    utils.kprint(" a5 : 0x{x} a6: 0x{x} a7 : 0x{x}\n", .{ regs.a5, regs.a6, regs.a7 });
    utils.kprint(" s2 : 0x{x} s3: 0x{x} s4 : 0x{x}\n", .{ regs.s2, regs.s3, regs.s4 });
    utils.kprint(" s5 : 0x{x} s6: 0x{x} s7 : 0x{x}\n", .{ regs.s5, regs.s6, regs.s7 });
    utils.kprint(" s8 : 0x{x} s9: 0x{x} s10: 0x{x}\n", .{ regs.s8, regs.s9, regs.s10 });
    utils.kprint(" s11: 0x{x} t3: 0x{x} t4 : 0x{x}\n", .{ regs.s11, regs.t3, regs.t4 });
    utils.kprint(" t5 : 0x{x} t6: 0x{x}\n", .{ regs.t5, regs.t6 });
}

fn doTrapError(regs: *trapFrame, msg: []const u8) void {
    utils.kprint("\n\nOops - {s}\n", .{msg});
    show_regs(regs);

    @panic("trap occurred\n");
}

// trap handler generater
fn generateErrorHandler(comptime name: []const u8) *const fn (*trapFrame, []const u8) u32 {
    _ = name;
    return struct {
        fn handler(regs: *trapFrame, msg: []const u8) u32 {
            doTrapError(regs, msg);
            return 0;
        }
    }.handler;
}

const doTrapInsnMisaligned = generateErrorHandler("doTrapInsnMisaligned");
const doTrapInsnFault = generateErrorHandler("doTrapInsnFault");
const doTrapInsnIllegal = generateErrorHandler("doTrapInsnIllegal");
const doTrapBreak = generateErrorHandler("doTrapBreak");
const doTrapLoadMisaligned = generateErrorHandler("doTrapLoadMisaligned");
const doTrapLoadFault = generateErrorHandler("doTrapLoadFault");
const doTrapStoreMisaligned = generateErrorHandler("doTrapStoreMisaligned");
const doTrapStoreFault = generateErrorHandler("doTrapStoreFault");
const doTrapEcallU = generateErrorHandler("doTrapEcallU");
const doTrapEcallS = generateErrorHandler("doTrapEcallS");
const doPageFault = generateErrorHandler("doPageFault");

const doTrapUnknown = generateErrorHandler("doTrapUnknown");

// a set of global fault infos
const FAULTINFOS = [16]FaultInfo{
    FaultInfo{ .fn_ptr = doTrapInsnMisaligned, .msg = "Instruction address misaligned" },
    FaultInfo{ .fn_ptr = doTrapInsnFault, .msg = "Instruction access fault" },
    FaultInfo{ .fn_ptr = doTrapInsnIllegal, .msg = "Illegal instruction" },
    FaultInfo{ .fn_ptr = doTrapBreak, .msg = "Breakpoint" },
    FaultInfo{ .fn_ptr = doTrapLoadMisaligned, .msg = "Load address misaligned" },
    FaultInfo{ .fn_ptr = doTrapLoadFault, .msg = "Load access fault" },
    FaultInfo{ .fn_ptr = doTrapStoreMisaligned, .msg = "Store/AMO address misaligned" },
    FaultInfo{ .fn_ptr = doTrapStoreFault, .msg = "Store/AMO access fault" },
    FaultInfo{ .fn_ptr = doTrapEcallU, .msg = "Environment call from U-mode" },
    FaultInfo{ .fn_ptr = doTrapEcallS, .msg = "Environment call from S-mode" },
    FaultInfo{ .fn_ptr = doTrapUnknown, .msg = "doTrapUnknown 10" },
    FaultInfo{ .fn_ptr = doTrapUnknown, .msg = "doTrapUnknown 11" },
    FaultInfo{ .fn_ptr = doPageFault, .msg = "Instruction page fault" },
    FaultInfo{ .fn_ptr = doPageFault, .msg = "Load page fault" },
    FaultInfo{ .fn_ptr = doTrapUnknown, .msg = "doTrapUnknown 10" },
    FaultInfo{ .fn_ptr = doPageFault, .msg = "Load page fault" },
};

fn isIntterruptFault(scause: usize) bool {
    return (scause & SCAUSE_INT) != 0;
}

inline fn ec2FaultInfo(scause: usize) *const FaultInfo {
    utils.kprint("scause : 0x{x}\n", .{scause});
    const index = scause & SCAUSE_EC;
    return &FAULTINFOS[index];
}

pub fn kTrapExceptionHandler(regs: *trapFrame, scause: usize) usize {
    bootTrace("S: exception handler enter\n");
    if (isIntterruptFault(scause)) {
        switch (scause & ~SCAUSE_INT) {
            INTERRUPT_CAUSE_TIMER => {
                timer.handleTimerIrq();
                return INTERRUPT_CAUSE_TIMER;
            },
            INTERRUPT_CAUSE_EXTERNAL => {
                plic.handlerPlicIrq();
                return INTERRUPT_CAUSE_EXTERNAL;
            },
            else => {
                utils.kprint("not support this type interrupt\n", .{});
                return (0xffff);
            },
        }
    } else {
        var fi = ec2FaultInfo(scause);
        if (fi.fn_ptr(regs, fi.msg) == 0) {
            return 0xffff;
        }
    }

    return 0xffff;
}

// callconv(.naked) mean compiler could not 'generate prologue and epilogue'
// need programmer implement manually
extern fn doKernelExceptionVector() callconv(.naked) void;
pub fn trapInit() void {
    io.writeCsr("sscratch", 0);

    // set execption vector
    io.writeCsr("stvec", @intFromPtr(&doKernelExceptionVector));

    if (comptime boot_trace) {
        const stvec_val = io.readCsr("stvec");
        utils.kprint("stvec=0x{x}, doExceptionVector addres 0x{x}\n", .{ stvec_val, @intFromPtr(&doKernelExceptionVector) });
    }

    // set all interrupt
    io.writeCsr("sie", @bitCast(@as(i64, -1)));
}

// user
const SSTATUS_SPP: usize = (0x1 << 8); // Previous mode, 1=Supervisor, 0=User
const SSTATUS_SPIE: usize = (0x1 << 5); // Supervisor Previous Interrupt Enable
pub fn usertrap() callconv(.c) void {
    // send interrupts and exceptions to kerneltrap(),
    // since we're now in the kernel.
    io.writeCsr("stvec", @intFromPtr(&doKernelExceptionVector));
    bootTrace("T: usertrap enter\n");
    var exception_num: usize = 0;

    var t = task.TaskCpu.currentTcb().?;
    const sstatus = t.trapframe.sstatus;
    if (comptime boot_trace) {
        bootTrace("T: usertrap sstatus=");
        bootTraceHex(sstatus);
        bootTrace("\n");
    }
    if ((sstatus & SSTATUS_SPP) != 0) {
        @panic("usertrap: not on user mode");
    }

    bootTrace("T: usertrap kernel stvec installed\n");

    if (comptime boot_trace) {
        bootTrace("T: usertrap tcb=");
        bootTraceHex(@intFromPtr(t));
        bootTrace("\n");
    }

    // save user programmer counter
    const scause = t.trapframe.scause;
    if (comptime boot_trace) {
        bootTrace("T: trap scause=");
        bootTraceHex(scause);
        bootTrace(" sepc=");
        bootTraceHex(t.trapframe.sepc);
        bootTrace(" tf=");
        bootTraceHex(@intFromPtr(t.trapframe));
        bootTrace("\n");
    }
    if (scause == EXC_SYSCALL) {
        if (comptime boot_trace) {
            bootTrace("T: syscall a7=");
            bootTraceHex(t.trapframe.a7);
            bootTrace(" a0=");
            bootTraceHex(t.trapframe.a0);
            bootTrace(" a1=");
            bootTraceHex(t.trapframe.a1);
            bootTrace("\n");
        }

        if (t.isKilled()) {
            proc.exit(-1);
        }

        t.trapframe.sepc += 4;

        bootTrace("T: syscall handler enter\n");
        syscall.trapSyscallHandler(t.trapframe);
        bootTrace("T: syscall handler leave\n");

        if (comptime boot_trace) {
            bootTrace("T: syscall returned a0=");
            bootTraceHex(t.trapframe.a0);
            bootTrace(" sepc=");
            bootTraceHex(t.trapframe.sepc);
            bootTrace("\n");
        }

        riscv.archLocalIrqEnable();
    } else {
        bootTrace("T: exception handler enter\n");
        exception_num = kTrapExceptionHandler(t.trapframe, scause);
        bootTrace("T: exception handler leave\n");
    }

    if (t.isKilled()) {
        proc.exit(-1);
    }

    if (exception_num == INTERRUPT_CAUSE_TIMER) {
        bootTrace("T: timer yield\n");
        proc.yield();
    }

    bootTrace("T: usertrap before return\n");
    usertrapret();
}

extern fn userret() callconv(.naked) void;
extern fn uservec() callconv(.naked) void;
extern fn trampoline() callconv(.naked) void;
pub fn usertrapret() callconv(.c) void {
    bootTrace("T: usertrapret enter\n");
    var t = task.TaskCpu.currentTcb().?;

    riscv.archLocalIrqDisable();

    const trampoline_uservec: usize = TRAMPOLINE + (@intFromPtr(&uservec) - @intFromPtr(&trampoline));
    io.writeCsr("stvec", trampoline_uservec);

    // ready to next trap into kernel from this task
    t.trapframe.kernel_satp = io.readCsr("satp");
    t.trapframe.kernel_sp = t.kstack + PAGE_SIZE * task.taskControlBlock.KSTACK_PAGES; // top-down growth
    t.trapframe.kernel_trap = @intFromPtr(&usertrap);
    t.trapframe.kernel_hartid = riscv.riscvReadTp();

    // set S Previous Privilege mode to User.
    // tell need to return privilege
    // SPP = 0 → sret back to user mode
    // SPP = 1 → sret back to kernel mode
    io.writeCsr("sstatus", (io.readCsr("sstatus") &
        ~SSTATUS_SPP) | // mean previouse is user mode
        SSTATUS_SPIE); // enable interrupt when back to user mode

    // set S Exception Program Counter to the saved user pc.
    io.writeCsr("sepc", t.trapframe.sepc);

    // tell trampoline.S the user page table to switch to.
    const satp: usize = riscv.SATP_SV39 | (@intFromPtr(t.pagetable.root) >> 12);

    // The C906 instruction cache is not coherent with stores that populated
    // a newly mapped executable page.
    asm volatile ("fence.i" ::: .{ .memory = true });
    bootTrace("T: usertrapret before userret\n");

    // jump to userret in trampoline.S at the top of memory, which
    // switches to the user page table, restores user registers,
    // and switches to user mode with sret.
    const userret_fn: *const fn (u64) callconv(.c) void =
        @ptrFromInt((TRAMPOLINE + (@intFromPtr(&userret) - @intFromPtr(&trampoline))));
    userret_fn(satp);
    utils.kprint("ERROR: cant access here \n", .{});
}

pub fn trapExceptionTest() void {
    asm volatile (
        \\ li a0, 0x7000000000
        \\ ld a0, (a0)
        \\ ret
    );
}
