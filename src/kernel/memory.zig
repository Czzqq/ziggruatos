const std = @import("std");

const arch = @import("arch");
const memory_backend = if (arch.memory_policy.enabled) @import("memory/sv39.zig") else @import("memory/nommu.zig");
const io = arch.io;
const riscv = arch.riscv;
const spinlock = arch.spinlock;

const board_cfg = @import("board").config;

const common = @import("common");
const utils = common.utils;
const address = common.address;

const pagetable = @import("pagetable.zig");

const SpinLock = spinlock.SpinLock;

const Page = address.Page;
const Virtaddress = address.VirtAddress;
const PhysicalAddress = address.PhysicalAddress;

const PageTable = pagetable.PageTable;
const PageTableEntry = pagetable.PageTableEntry;

const DDR_BASE: usize = board_cfg.dram.base;
const TOTAL_MEMORY: usize = board_cfg.kernel_memory.size;
const MEM_BASE: usize = board_cfg.kernel_memory.base;
const MEM_END: usize = board_cfg.kernel_memory.base + board_cfg.kernel_memory.size;

const PAGE_SIZE: usize = address.PAGE_SIZE;
const TRAMPOLINE: usize = address.TRAMPOLINE;
const boot_trace = @hasDecl(board_cfg, "boot_trace") and board_cfg.boot_trace;

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (comptime boot_trace) {
        utils.kprint(fmt, args);
    }
}

// VMA              section            LMA
// 0x80200000  ┌─────────────────┐
//             │  .text.boot     │  0x80200000
//             ├─────────────────┤
//             │  .text          │  0x80300000 (TEXT_ROM)
//             │  - code text    │
//             │  - trampoline   │
//             ├─────────────────┤
//             │  .rodata        │  (same VMA)
//             ├─────────────────┤
//             │  .data          │
//             ├─────────────────┤
//             │  .bss           │
//             ├─────────────────┤
//             │  .kernel        │
//             ├─────────────────┤
//             │  Reserved       │
// 0x80300000  ├─────────────────┤
// 32MB        │  phy memory     │
//             └─────────────────┘

// NOTE: other way to init a array
// var buf: [256]u8 = std.mem.zeroes([256]u8);
// var bit_map_buf: [8192]u8 = [_]u8{0} ** 8192;

// Maximum supported physical memory pages (for bitmap sizing)
const MAX_PAGES: usize = TOTAL_MEMORY / PAGE_SIZE; // 8192 pages
const BITMAP_SIZE: usize = (MAX_PAGES + 7) / 8; // 1024 bytes

// =============================================================================
// Error Types
// =============================================================================
pub const MemoryError = error{
    OutOfMemory,
    InvalidSize,
    InvalidAddress,
    InvalidAlignment,
    DoubleFree,
    NotInitialized,
    RangeExceeded,
};

pub fn sfenceVma() void {
    memory_backend.fence();
}

// =============================================================================
// Bump Allocator (for bootstrapping)
// =============================================================================

/// Simple bump allocator for early kernel initialization
/// Use this before the main memory system is ready
pub const BumpAllocator = struct {
    buffer: []u8,
    used: usize = 0,

    pub fn alloc(self: *BumpAllocator, comptime T: type, n: usize) MemoryError![]T {
        const requested_bytes = @sizeOf(T) * n;

        const alignment = @alignOf(T);
        const alignment_used = std.mem.alignForward(usize, self.used, alignment);

        if (alignment_used + requested_bytes > self.buffer.len) {
            return error.OutOfMemory;
        }

        const ptr = self.buffer[alignment_used .. alignment_used + requested_bytes].ptr;
        self.used = alignment_used + requested_bytes;
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..n];
    }

    pub fn free(self: *BumpAllocator, comptime T: type, items: []T) void {
        _ = items;
        _ = self;
    }

    pub fn reset(self: *BumpAllocator) void {
        self.used = 0;
    }
};

// =============================================================================
// Physical Memory Manager
// =============================================================================

/// Physical memory allocator using bitmap
/// Thread-safe operations should be added if used in SMP context
pub const PhyMemoryManager = struct {
    start: usize,
    end: usize,
    total_pages: usize,
    free_pages: usize,

    bit_map: []u8,

    const Self = @This();

    pub fn init(
        bitmap_storage: []u8,
        start_addr: usize,
        size: usize,
    ) MemoryError!Self {
        if (size == 0 or size % PAGE_SIZE != 0) {
            return error.InvalidSize;
        }
        if (start_addr % PAGE_SIZE != 0) {
            return error.InvalidSize;
        }
        const end_addr = std.math.add(usize, start_addr, size) catch return error.RangeExceeded;

        const total_pages = size / PAGE_SIZE;
        const required_bitmap_size = total_pages / 8 + @intFromBool(total_pages % 8 != 0);

        if (bitmap_storage.len < required_bitmap_size) {
            utils.kprint(
                "Bitmap buffer too small: need {}, have {}\n",
                .{ required_bitmap_size, bitmap_storage.len },
            );
            return MemoryError.OutOfMemory;
        }

        const bitmap = bitmap_storage[0..required_bitmap_size];
        @memset(bitmap, 0);

        utils.kprint(
            "PMM Init: start=0x{x}, size={}MB, pages={}, bitmap={}B\n",
            .{ start_addr, size / (1024 * 1024), total_pages, bitmap.len },
        );
        // kernel start 0x80200000
        // reservd 1MB , so start address is 0x80300000
        // end 0x823000000

        // 32 MB total size
        // 8 KB bit-map to map 0x80300000 to 82300000
        // for (bit_map) |*byte| {
        //     byte.* = @as(u8, 0);
        // }

        return Self{
            .start = start_addr,
            .end = end_addr,
            .total_pages = total_pages,
            .free_pages = total_pages,
            .bit_map = bitmap,
        };
    }

    inline fn validateAddress(self: *const Self, phys_addr: usize) MemoryError!void {
        if (phys_addr % PAGE_SIZE != 0) {
            return MemoryError.InvalidAlignment;
        }
        if (phys_addr < self.start or phys_addr >= self.end) {
            return MemoryError.InvalidAddress;
        }
    }

    inline fn markFree(self: Self, page_index: usize) void {
        const bytes_index = page_index / 8;
        const bit_index = @as(u3, @intCast(page_index % 8));

        self.bit_map[bytes_index] &= ~(@as(u8, 1) << bit_index);
    }

    inline fn markAlloced(self: Self, page_index: usize) void {
        const bytes_index = page_index / 8;
        const bit_index = @as(u3, @intCast(page_index % 8));

        self.bit_map[bytes_index] |= (@as(u8, 1) << bit_index);
    }

    // check if the bit status
    fn isAlloced(self: Self, page_index: usize) bool {
        const bytes_index = page_index / 8;
        const bit_index = @as(u3, @intCast(page_index % 8));

        return (self.bit_map[bytes_index] & (@as(u8, 1) << bit_index) != 0);
    }

    fn findFreePageIndex(self: Self) ?usize {
        for (0..(self.total_pages)) |x| {
            if (!self.isAlloced(x))
                return x;
        }
        return null;
    }

    // return real phy address
    pub fn allocPage(self: *Self) MemoryError!usize {
        if (self.free_pages == 0) return MemoryError.OutOfMemory;

        const index = self.findFreePageIndex() orelse {
            return MemoryError.OutOfMemory;
        };

        self.markAlloced(index);
        self.free_pages -= 1;

        return self.start + index * PAGE_SIZE;
    }

    pub fn allocContinuous(self: *Self, count: usize) MemoryError!usize {
        if (count == 0) return MemoryError.InvalidSize;
        if (self.free_pages < count) return MemoryError.OutOfMemory;

        var start_index: usize = 0;
        while (start_index <= self.total_pages - count) {
            const end_index = start_index + count;
            var found = true;
            var i: usize = start_index;

            while (i < end_index) : (i += 1) {
                if (self.isAlloced(i)) {
                    start_index = i + 1;
                    found = false;
                    break;
                }
            }

            if (found) {
                for (start_index..end_index) |idx| {
                    self.markAlloced(idx);
                }
                self.free_pages -= count;
                return self.start + start_index * PAGE_SIZE;
            }
        }
        return MemoryError.OutOfMemory;
    }

    pub fn freePage(self: *Self, addr: usize) MemoryError!void {
        try self.validateAddress(addr);

        const page_index = (addr - self.start) / PAGE_SIZE;

        if (!self.isAlloced(page_index)) {
            utils.kprint("trying to free already free page at 0x{X}\n", .{addr});
            return MemoryError.DoubleFree;
        }

        self.markFree(page_index);

        @memset(@as([*]u8, @ptrFromInt(addr))[0..(PAGE_SIZE - 1)], 0);
        self.free_pages += 1;
    }

    pub fn freeContinuous(self: *Self, addr: usize, count: usize) MemoryError!void {
        if (count == 0) return MemoryError.InvalidSize;
        try self.validateAddress(addr);

        const start_index = (addr - self.start) / PAGE_SIZE;

        if (count > self.total_pages - start_index) {
            return MemoryError.RangeExceeded;
        }

        for (start_index..start_index + count) |i| {
            if (!self.isAlloced(i)) {
                return MemoryError.DoubleFree;
            }
        }
        for (start_index..start_index + count) |i| {
            self.markFree(i);
        }
        self.free_pages += count;
    }

    pub fn debugDump(self: Self) void {
        utils.kprint(
            "PMM Info: start=0x{x}, end=0x{x}, total_pages={}, free_pages={}\n",
            .{ self.start, self.end, self.total_pages, self.free_pages },
        );
    }
};

pub const VirtMemoryManager = struct {
    kernel_pagetable: PageTable = undefined,

    const Self = @This();

    extern fn trampoline() callconv(.naked) void;

    pub fn getGlobalPageTable(self: Self) ?PageTable {
        if (!@hasDecl(@This(), "kernel_pagetable")) return null;

        return self.kernel_pagetable;
    }

    fn vmmake(pmm: *PhyMemoryManager) !PageTable {
        const page_table_addr = try pmm.allocPage();
        trace("Page table: root allocated at 0x{x}\n", .{page_table_addr});

        var page_table = PageTable{
            .root = @ptrFromInt(page_table_addr),
        };

        @memset(std.mem.asBytes(page_table.root), 0);
        trace("Page table: root initialized\n", .{});

        // UART
        try page_table.mmapRange(
            board_cfg.uart0.base,
            board_cfg.uart0.base,
            PAGE_SIZE,
            pagetable.deviceFlags(pagetable.PTE_R | pagetable.PTE_W),
        );
        trace("Page table: UART mapped\n", .{});

        // PLIC
        try page_table.mmapRange(
            board_cfg.plic.base,
            board_cfg.plic.base,
            0x4000000,
            pagetable.deviceFlags(pagetable.PTE_R | pagetable.PTE_W),
        );
        trace("Page table: PLIC mapped\n", .{});

        if (comptime @hasDecl(board_cfg, "virtio_mmio")) {
            const mmio = board_cfg.virtio_mmio;
            try page_table.mmapRange(
                mmio.base,
                mmio.base,
                mmio.stride * mmio.count,
                pagetable.deviceFlags(pagetable.PTE_R | pagetable.PTE_W),
            );
            trace("Page table: virtio MMIO mapped\n", .{});
        }

        // kernel text section
        try page_table.mmapRange(DDR_BASE, DDR_BASE, @as(u64, @intFromPtr(&utils.etext)) - DDR_BASE, pagetable.PTE_X | pagetable.PTE_R);
        trace("Page table: kernel text mapped\n", .{});

        // kernel data section
        try page_table.mmapRange(@as(u64, @intFromPtr(&utils.etext)), @as(u64, @intFromPtr(&utils.etext)), MEM_END - @as(u64, @intFromPtr(&utils.etext)), pagetable.PTE_R | pagetable.PTE_W);
        trace("Page table: kernel data mapped\n", .{});

        try page_table.mmapRange(TRAMPOLINE, @intFromPtr(&trampoline), PAGE_SIZE, pagetable.PTE_X | pagetable.PTE_R);
        trace("Page table: trampoline mapped\n", .{});

        // allocate and map a kernel stack for each process.
        // at alloc proc dynamic vmmap the kstack

        if (comptime !board_cfg.initramfs.embedded) {
            try page_table.mmapRange(
                board_cfg.initramfs.base,
                board_cfg.initramfs.base,
                board_cfg.initramfs.max_size,
                pagetable.PTE_R | pagetable.PTE_W | pagetable.PTE_X,
            );
        }

        trace("Page table: construction complete\n", .{});
        return page_table;
    }

    // kernel page table init
    pub fn initKernelPageTable(pmm: *PhyMemoryManager) MemoryError!Self {
        if (comptime !arch.memory_policy.enabled) @compileError("Sv39 initialization is disabled by -Dmmu=off");
        return Self{
            .kernel_pagetable = try vmmake(pmm),
        };
    }

    pub fn getPageTable(self: *Self) *PageTable {
        return &self.kernel_pagetable;
    }

    // turn on paging
    pub fn inithart(self: Self) void {
        if (comptime !arch.memory_policy.enabled) @compileError("satp activation is disabled by -Dmmu=off");
        utils.kprint("Activating Sv39 paging...\n", .{});
        sfenceVma();
        io.writeCsr("satp", riscv.SATP_SV39 |
            (@intFromPtr(self.kernel_pagetable.root) >> 12));
        // flush tlb
        sfenceVma();
        utils.kprint("Sv39 paging active.\n", .{});
    }
};

pub const MemorySystem = struct {
    pmm: PhyMemoryManager,
    vmm: VirtMemoryManager,
    initialized: bool,

    const Self = @This();

    pub var instance: ?Self = null;
    var alloc_lock: SpinLock = SpinLock.init("physical_memory");
    var bitmap_buffer: [BITMAP_SIZE]u8 = undefined;

    /// Get the global memory system instance
    pub fn get() MemoryError!*Self {
        return &(instance orelse return MemoryError.NotInitialized);
    }

    pub fn init() MemoryError!void {
        if (instance != null) {
            return;
        }

        instance = Self{
            .pmm = try PhyMemoryManager.init(bitmap_buffer[0..], MEM_BASE, TOTAL_MEMORY),
            .vmm = undefined,
            .initialized = false,
        };

        instance.?.vmm = try memory_backend.initialize(VirtMemoryManager, &instance.?.pmm);
        instance.?.initialized = true;


        utils.kprint("Memory system initialized successfully.\n", .{});
    }

    pub fn kalloc(comptime T: type, count: usize) MemoryError!*T {
        alloc_lock.acquire();
        defer alloc_lock.release();
        const sys = try get();
        const size = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        if (size == 0)
            return error.InvalidSize;

        const align_count = size / PAGE_SIZE + @intFromBool(size % PAGE_SIZE != 0);
        var paddr: usize = 0;

        if (align_count > 1) {
            paddr = try sys.pmm.allocContinuous(align_count);
        } else {
            paddr = try sys.pmm.allocPage();
        }

        return @ptrFromInt(paddr);
    }

    pub fn kfree(comptime T: type, ptr: *T, count: usize) MemoryError!void {
        alloc_lock.acquire();
        defer alloc_lock.release();
        const sys = try get();
        const size = std.math.mul(usize, @sizeOf(T), count) catch return error.RangeExceeded;
        if (size == 0) {
            return error.InvalidSize;
        }

        const align_count = size / PAGE_SIZE + @intFromBool(size % PAGE_SIZE != 0);

        if (align_count > 1) {
            try sys.pmm.freeContinuous(@intFromPtr(ptr), align_count);
        } else {
            try sys.pmm.freePage(@intFromPtr(ptr));
        }
    }
};

// =============================================================================
// Kernel Heap Allocator
// =============================================================================

/// Block metadata stored before each allocation
const BlockHeader = extern struct {
    size: usize,
    allocation_size: usize,
    base: usize,
    magic: u32,

    const MAGIC: u32 = 0xDEADBEEF;

    fn fromPtr(ptr: [*]u8) *BlockHeader {
        const header_addr = @intFromPtr(ptr) - @sizeOf(BlockHeader);
        return @ptrFromInt(header_addr);
    }

    fn validate(self: *const BlockHeader) bool {
        return self.magic == MAGIC;
    }

    fn toDataPtr(self: *const BlockHeader) [*]u8 {
        const data_addr = @intFromPtr(self) + @sizeOf(BlockHeader);

        return @ptrFromInt(data_addr);
    }

    fn capacity(self: *const BlockHeader) usize {
        return self.base + self.allocation_size - @intFromPtr(self.toDataPtr());
    }
};

/// Small block pool for allocations < PAGE_SIZE
const SmallBlockPool = struct {
    // Free list organized by size classes
    const SIZE_CLASS_COUNT = 8;
    const SIZE_CLASSES = [SIZE_CLASS_COUNT]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

    /// Free block node in linked list
    const FreeNode = struct {
        next: ?*FreeNode,
        size: usize,
    };

    free_lists: [SIZE_CLASS_COUNT]?*FreeNode,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .free_lists = @splat(null),
        };
    }

    /// Find appropriate size class for allocation
    fn getSizeClass(size: usize) ?usize {
        for (SIZE_CLASSES, 0..) |class_size, i| {
            if (size <= class_size) return i;
        }
        return null;
    }

    /// Allocate from small block pool
    pub fn alloc(self: *Self, size: usize) ![]u8 {
        const size_class = getSizeClass(size) orelse return error.TooLarge;
        const actual_size = SIZE_CLASSES[size_class];

        // try to get from free list
        if (self.free_lists[size_class]) |node| {
            self.free_lists[size_class] = node.next;
            const ptr: [*]u8 = @ptrCast(node);
            return ptr[0..actual_size];
        }

        // Allocate new page and carve blocks from it
        return self.allocFromNewPage(actual_size);
    }

    fn allocFromNewPage(self: *Self, size: usize) ![]u8 {
        const page_addr = try MemorySystem.kalloc(u8, PAGE_SIZE);

        const page_ptr: [*]u8 = @ptrCast(page_addr);
        @memset(page_ptr[0..PAGE_SIZE], 0);

        // Carve the first block for return
        const first_block = page_ptr[0..size];

        // Add remaining blocks to free list
        const size_class = getSizeClass(size).?;
        var offset = size;

        while (offset + size <= PAGE_SIZE) : (offset += size) {
            const node: *FreeNode = @ptrCast(@alignCast(page_ptr + offset));
            node.size = size;
            node.next = self.free_lists[size_class];
            self.free_lists[size_class] = node;
        }

        return first_block;
    }

    /// Return block to free list
    pub fn free(self: *Self, buf: []u8) void {
        const size_class = getSizeClass(buf.len) orelse {
            utils.kprint("Invalid small block size: {}\n", .{buf.len});
            return;
        };

        @memset(buf, 0);

        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.size = buf.len;
        node.next = self.free_lists[size_class];
        self.free_lists[size_class] = node;
    }
};

/// Main kernel heap allocator
pub const KernelHeapAllocator = struct {
    small_pool: SmallBlockPool,

    const Self = @This();
    const SMALL_THRESHOLD = 2048; // Use pool for allocations <= 2KB

    var instance: ?Self = null;
    var heap_lock: SpinLock = SpinLock.init("kernel_heap");

    pub fn init() void {
        if (instance == null) {
            instance = Self{
                .small_pool = SmallBlockPool.init(),
            };
            utils.kprint("Kernel heap allocator initialized.\n", .{});
        }
    }

    pub fn get() !*Self {
        return &(instance orelse return error.NotInitialized);
    }

    /// Get the standard Zig allocator interface
    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize, // ret_addr
    ) ?[*]u8 {
        heap_lock.acquire();
        defer heap_lock.release();
        const align_value: usize = alignment.toByteUnits();

        if (len == 0) {
            return null;
        }

        const padded_size = std.math.add(usize, len, @sizeOf(BlockHeader)) catch return null;
        const required_size = std.math.add(usize, padded_size, align_value - 1) catch return null;

        const result = if (required_size <= SMALL_THRESHOLD) blk: {
            break :blk allocSmall(len, required_size, align_value) catch {
                return null;
            };
        } else blk: {
            break :blk allocLarge(len, required_size, align_value) catch {
                return null;
            };
        };

        return result;
    }

    fn allocSmall(len: usize, required_size: usize, alignment: usize) !?[*]u8 {
        const self = try get();

        // Try to allocate from small pool
        const buf = self.small_pool.alloc(required_size) catch |err| {
            if (err == error.TooLarge) {
                // Fallback to large allocation
                return allocLarge(len, required_size, alignment);
            }
            return null;
        };

        const base = @intFromPtr(buf.ptr);
        const data_addr = std.mem.alignForward(usize, base + @sizeOf(BlockHeader), alignment);
        const header: *BlockHeader = @ptrFromInt(data_addr - @sizeOf(BlockHeader));
        header.* = .{
            .size = len,
            .allocation_size = buf.len,
            .base = base,
            .magic = BlockHeader.MAGIC,
        };

        const data_ptr = header.toDataPtr();
        @memset(data_ptr[0..len], 0);

        return data_ptr;
    }

    fn allocLarge(len: usize, required_size: usize, alignment: usize) !?[*]u8 {
        const page_count = required_size / PAGE_SIZE + @intFromBool(required_size % PAGE_SIZE != 0);
        const allocation_size = std.math.mul(usize, page_count, PAGE_SIZE) catch return null;
        const page_ptr_single = MemorySystem.kalloc(u8, allocation_size) catch {
            return null;
        };

        // Convert *u8 to [*]u8
        const page_ptr: [*]u8 = @ptrCast(page_ptr_single);

        // Clear the entire allocation
        @memset(page_ptr[0..allocation_size], 0);

        const base = @intFromPtr(page_ptr);
        const data_addr = std.mem.alignForward(usize, base + @sizeOf(BlockHeader), alignment);
        const header: *BlockHeader = @ptrFromInt(data_addr - @sizeOf(BlockHeader));
        header.* = .{
            .size = len,
            .allocation_size = allocation_size,
            .base = base,
            .magic = BlockHeader.MAGIC,
        };

        return header.toDataPtr();
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        _: usize, // ret_addr
    ) bool {
        _ = alignment;

        if (buf.len == 0 or new_len == 0) {
            return false;
        }

        const header = BlockHeader.fromPtr(buf.ptr);

        if (!header.validate()) {
            return false;
        }

        const old_size = header.capacity();

        // Can shrink in place
        if (new_len <= old_size) {
            return true;
        }

        // Can't grow in place
        return false;
    }

    fn remap(
        _: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        _: usize, // ret_addr
    ) ?[*]u8 {
        _ = alignment;

        const header = BlockHeader.fromPtr(buf.ptr);

        if (!header.validate()) {
            return null;
        }

        const old_size = header.capacity();

        // If shrinking or same size, return original pointer
        if (new_len <= old_size) {
            return buf.ptr;
        }

        // Can't grow in place
        return null;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        _: std.mem.Alignment,
        _: usize, // ret_addr
    ) void {
        heap_lock.acquire();
        defer heap_lock.release();
        if (buf.len == 0) return;

        const header = BlockHeader.fromPtr(buf.ptr);

        if (!header.validate()) {
            utils.kprint("Free: corrupted header at 0x{X}\n", .{@intFromPtr(buf.ptr)});
            return;
        }

        // Clear magic to detect double-free
        header.magic = 0;

        if (header.allocation_size <= SMALL_THRESHOLD) {
            freeSmall(header) catch |err| {
                utils.kprint("Failed to free small block: {}\n", .{err});
            };
        } else {
            freeLarge(header) catch |err| {
                utils.kprint("Failed to free large block: {}\n", .{err});
            };
        }
    }

    fn freeSmall(header: *BlockHeader) !void {
        const self = try get();
        const buf_ptr: [*]u8 = @ptrFromInt(header.base);
        const buf = buf_ptr[0..header.allocation_size];
        self.small_pool.free(buf);
    }

    fn freeLarge(header: *BlockHeader) !void {
        const ptr: *u8 = @ptrFromInt(header.base);
        try MemorySystem.kfree(u8, ptr, header.allocation_size);
    }

    /// Debug: print allocator statistics
    pub fn debugStats(self: *Self) void {
        utils.kprint("=== Kernel Heap Statistics ===\n", .{});

        for (self.small_pool.free_lists, 0..) |list, i| {
            var count: usize = 0;
            var current = list;

            while (current) |node| : (current = node.next) {
                count += 1;
            }

            if (count > 0) {
                utils.kprint("  Size class {} ({}B): {} free blocks\n", .{ i, SmallBlockPool.SIZE_CLASSES[i], count });
            }
        }
    }
};

// =============================================================================
// Convenience wrapper
// =============================================================================

/// Global kernel allocator instance
pub fn kernelAllocator() std.mem.Allocator {
    return KernelHeapAllocator.allocator();
}

/// Initialize the kernel heap
pub fn initKernelHeap() !void {
    KernelHeapAllocator.init();
}

// =============================================================================
// Testing utilities
// =============================================================================

pub fn testAllocator() !void {
    utils.kprint("\n=== Testing Kernel Allocator ===\n", .{});

    const allocator = kernelAllocator();

    // Test 1: Small allocations
    utils.kprint("Test 1: Small allocations\n", .{});
    const small1 = try allocator.alloc(u8, 16);
    defer allocator.free(small1);
    utils.kprint("  Allocated 16 bytes at 0x{x}\n", .{@intFromPtr(small1.ptr)});

    const small2 = try allocator.alloc(u8, 64);
    defer allocator.free(small2);
    utils.kprint("  Allocated 64 bytes at 0x{x}\n", .{@intFromPtr(small2.ptr)});

    // Test 2: Large allocation
    utils.kprint("Test 2: Large allocation\n", .{});
    const large = try allocator.alloc(u8, 8192);
    defer allocator.free(large);
    utils.kprint("  Allocated 8192 bytes at 0x{x}\n", .{@intFromPtr(large.ptr)});

    // Test 3: Struct allocation
    utils.kprint("Test 3: Struct allocation\n", .{});
    const TestStruct = struct {
        a: u64,
        b: u64,
        c: [32]u8,
    };

    const structs = try allocator.alloc(TestStruct, 10);
    defer allocator.free(structs);
    utils.kprint("  Allocated 10 TestStructs at 0x{x}\n", .{@intFromPtr(structs.ptr)});

    structs[0].a = 0x1234567890ABCDEF;
    utils.kprint("  structs[0].a = 0x{x}\n", .{structs[0].a});

    utils.kprint("Test 4: ArrayList with kernel allocator\n", .{});
    var list: std.ArrayList(u32) = try std.ArrayList(u32).initCapacity(allocator, 0);
    defer list.deinit(allocator);

    try list.append(allocator, 10);
    try list.append(allocator, 20);
    try list.append(allocator, 30);

    utils.kprint("  ArrayList contents: ", .{});
    for (list.items) |item| {
        utils.kprint("{} ", .{item});
    }
    utils.kprint("\n", .{});

    utils.kprint("Test 5: HashMap with kernel allocator\n", .{});

    utils.kprint("  Step 1: Creating HashMap...\n", .{});
    var map = std.AutoHashMap(u32, u32).init(allocator);
    utils.kprint("  HashMap created successfully\n", .{});
    defer map.deinit();

    utils.kprint("  Step 2: First put (will trigger initial allocation)...\n", .{});
    const sys = try MemorySystem.get();
    sys.pmm.debugDump();

    const count = 5;
    var i: u32 = 0;
    var total: u32 = 0;
    while (i < count) : (i += 1) {
        try map.put(i, i);
        total += i;
    }

    sys.pmm.debugDump();

    utils.kprint("          Second put...\n", .{});
    try map.put(2, 200);
    utils.kprint("  Second put succeeded\n", .{});

    try map.put(3, 300);
    utils.kprint("  Third put succeeded\n", .{});

    utils.kprint("  HashMap size: {}\n", .{map.count()});
    if (map.get(2)) |val| {
        utils.kprint("  map[2] = {}\n", .{val});

        // Test 6: String operations
        utils.kprint("Test 6: String operations\n", .{});
        var str = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer str.deinit(allocator);

        try str.appendSlice(allocator, "Hello from kernel heap!");
        utils.kprint("  String: {s}\n", .{str.items});

        utils.kprint("=== All tests passed! ===\n\n", .{});
    }
}

// =====================================================================
// Public API (for compatibility)
// =====================================================================

/// Initialize the memory subsystem (main entry point)
pub fn memInit() void {
    MemorySystem.init() catch |err| {
        utils.kprint("Memory initialization failed: {}\n", .{err});
        @panic("Cannot initialize memory system\n");
    };

    initKernelHeap() catch |err| {
        utils.kprint("kernel heap initialization failed: {}\n", .{err});
        @panic("Cannot initialize kernel allocator\n");
    };
}
// Now you can use std containers
// var list = std.ArrayList(u32).init(mem.kernel_allocator);
// defer list.deinit();

/// Allocate kernel memory
pub fn kalloc(comptime T: type, count: usize) MemoryError!*T {
    return MemorySystem.kalloc(T, count);
}

/// Free kernel memory
pub fn kfree(comptime T: type, ptr: *T, count: usize) void {
    MemorySystem.kfree(T, ptr, count) catch |err| {
        utils.kprint("kfree failed: {}\n", .{err});
        @panic("Memory free failed");
    };
}

/// Get kernel page table
pub fn getKernelPageTable() ?*PageTable {
    if (comptime !arch.memory_policy.enabled) return null;
    const sys = MemorySystem.get() catch return null;
    return sys.vmm.getPageTable();
}
