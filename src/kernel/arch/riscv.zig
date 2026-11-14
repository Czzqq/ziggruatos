const io = @import("io.zig");
const mmu_enabled = @import("memory_policy").enabled;
const irq_status = if (mmu_enabled) "sstatus" else "mstatus";
const irq_enable: usize = if (mmu_enabled) 2 else 8;
const address = @import("common").address;

// sv39 page table scheme
pub const SATP_SV39: usize = (8 << 60);

// ├─────────────────────────┤ 0x4000000000 (MAXVA)
// │ Trampoline Page │ user↔kernel switch
// ├─────────────────────────┤ 0x3ffffff000 (TRAMPOLINE)
// │ Trapframe Page │   save user frame
// ├─────────────────────────┤ 0x3fffffe000 (TRAPFRAME)
// │ │
// │ Process 0 KSTACK │
// │ ├─ Guard Page (4KB) │ 0x3fffffb000 (unmapped)
// │ ├─ Stack Page 1 (4KB) │ 0x3fffffc000
// │ └─ Stack Page 2 (4KB) │ 0x3fffffd000 ← SP = 0x3fffffe000
// ├─────────────────────────┤
// │ Process 1 KSTACK │
// │ ├─ Guard Page (4KB) │ 0x3fffff8000 (unmapped)
// │ ├─ Stack Page 1 (4KB) │ 0x3fffff9000
// │ └─ Stack Page 2 (4KB) │ 0x3fffffa000 ← SP = 0x3fffffb000
// ├─────────────────────────┤
// │ Process 2 KSTACK │
// │ ├─ Guard Page (4KB) │ 0x3fffff5000 (unmapped)
// │ ├─ Stack Page 1 (4KB) │ 0x3fffff6000
// │ └─ Stack Page 2 (4KB) │ 0x3fffff7000 ← SP = 0x3fffff8000
// ├─────────────────────────┤
// │ ... │               task with 12KB
// ├─────────────────────────┤
// │ │
// │ Kernel Space │ kernel code/data/device mmap
// │ │
// ├─────────────────────────┤
// │ │
// │ User Space │ user code/data/heap/stack
// │ │
// ├─────────────────────────┤ 0x1000
// │ NULL Page │  catch null pointer (unmapped)
// ├─────────────────────────┤ 0x0

pub const SIE_SEIE: usize = 0x200;
pub const SR_SIE: usize = 0x2; // Supervisor Interrupt Enable (1 << 2)
pub fn archLocalIrqState() bool {
    return ((io.readCsr(irq_status) & irq_enable) != 0);
}

pub fn archLocalIrqEnable() void {
    io.setCsr(irq_status, irq_enable);
}

pub fn archLocalIrqDisable() void {
    io.clearCsr(irq_status, irq_enable);
}

pub fn readTime() u64 {
    return asm volatile ("rdtime %[time]" : [time] "=r" (-> u64));
}

pub fn readHart() usize {
    return asm volatile ("mv %[hart], tp" : [hart] "=r" (-> usize));
}

pub fn riscvReadTp() usize {
    var tp: usize = undefined;
    asm volatile ("mv %[result], tp"
        : [result] "=r" (tp),
        :
        : .{ .memory = true });

    return tp;
}

pub fn riscvWriteTp(hartid: usize) void {
    asm volatile ("mv tp, %[cpu]"
        :
        : [cpu] "r" (hartid),
        : .{ .memory = true });
}
