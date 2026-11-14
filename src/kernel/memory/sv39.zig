pub fn initialize(comptime Manager: type, physical: anytype) !Manager {
    const manager = try Manager.initKernelPageTable(physical);
    manager.inithart();
    return manager;
}

pub fn fence() void {
    asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
}
