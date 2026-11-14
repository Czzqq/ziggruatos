pub const PAGE_SHIFT: usize = 12;
pub const PAGE_SIZE: usize = 1 << PAGE_SHIFT;

pub const MAX_VA: usize = 1 << (9 + 9 + 9 + 12 - 1);
pub const TRAMPOLINE: usize = MAX_VA - PAGE_SIZE;
pub const TRAPFRAME: usize = MAX_VA - 2 * PAGE_SIZE;
pub const USER_BUFFER_SIZE: usize = 8192;

pub const Page = struct {
    pub inline fn roundDown(addr: usize) usize {
        return addr & ~(PAGE_SIZE - 1);
    }

    pub inline fn roundUp(addr: usize) usize {
        return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    }

    pub inline fn offset(addr: usize) usize {
        return addr & (PAGE_SIZE - 1);
    }

    pub inline fn isAligned(addr: usize) bool {
        return (addr & (PAGE_SIZE - 1)) == 0;
    }

    pub inline fn number(addr: usize) usize {
        return addr >> PAGE_SHIFT;
    }

    pub inline fn fromNumber(pfn: usize) usize {
        return pfn << PAGE_SHIFT;
    }

    pub fn countBetween(start: usize, end: usize) usize {
        return (roundUp(end) - roundDown(start)) / PAGE_SIZE;
    }
};

pub const VirtAddress = struct {
    addr: usize,

    pub fn init(addr: usize) VirtAddress {
        return .{ .addr = addr };
    }

    pub fn into(self: VirtAddress, comptime T: type) T {
        return switch (T) {
            usize => self.addr,
            else => @compileError("Cannot convert VirtAddress to" ++ @typeName(T)),
        };
    }

    pub fn roundDown(self: VirtAddress) VirtAddress {
        return .{ .addr = Page.roundDown(self.addr) };
    }

    pub fn roundUp(self: VirtAddress) VirtAddress {
        return .{ .addr = Page.roundUp(self.addr) };
    }

    pub fn offset(self: VirtAddress) usize {
        return Page.offset(self.addr);
    }

    pub fn isAligned(self: VirtAddress) bool {
        return Page.isAligned(self.addr);
    }

    pub fn vpn(self: VirtAddress, level: usize) usize {
        return (self.addr >> @as(u6, @intCast(PAGE_SHIFT + 9 * level))) & 0x1FF;
    }
};

pub const PhysicalAddress = struct {
    addr: usize,

    pub fn init(addr: usize) PhysicalAddress {
        return .{ .addr = addr };
    }

    pub fn into(self: PhysicalAddress, comptime T: type) T {
        return switch (T) {
            usize => self.addr,
            else => @compileError("Cannot convert PhysicalAddress to" ++ @typeName(T)),
        };
    }

    pub fn roundDown(self: PhysicalAddress) PhysicalAddress {
        return .{ .addr = Page.roundDown(self.addr) };
    }

    pub fn roundUp(self: PhysicalAddress) PhysicalAddress {
        return .{ .addr = Page.roundUp(self.addr) };
    }

    pub fn ppn(self: PhysicalAddress) usize {
        return Page.number(self.addr);
    }

    pub fn fromPpn(ppn_val: usize) PhysicalAddress {
        return .{ .addr = Page.fromNumber(ppn_val) };
    }
};
