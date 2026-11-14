const std = @import("std");
const memory = @import("memory.zig");
const riscv = @import("arch").riscv;
const elf = @import("common").elf;
const board_cfg = @import("board").config;

const address = @import("common").address;
const PhysicalAddress = address.PhysicalAddress;
const VirtAddress = address.VirtAddress;
const Page = address.Page;

const PAGE_SIZE = address.PAGE_SIZE;
const SUPER_PAGE_SHIFT: usize = 21;
const SUPER_PAGE_SIZE: usize = 1 << SUPER_PAGE_SHIFT;
const MAX_VA = address.MAX_VA;

const kalloc = memory.kalloc;
const kfree = memory.kfree;

const kprint = @import("common").utils.kprint;

const PA_WIDTH: usize = 56;
const PPN_BITS: usize = PA_WIDTH - address.PAGE_SHIFT;

const VA_BITS: usize = 39;
const VPN_MASK: usize = 0x1FF;

pub const PTE_V: u64 = 1 << 0;
pub const PTE_R: u64 = 1 << 1;
pub const PTE_W: u64 = 1 << 2;
pub const PTE_X: u64 = 1 << 3;
pub const PTE_U: u64 = 1 << 4;
pub const PTE_G: u64 = 1 << 5;
pub const PTE_A: u64 = 1 << 6;
pub const PTE_D: u64 = 1 << 7;

// T-HEAD C9xx uses Sv39 PTE bits 63:59 for cache and ordering attributes.
pub const PTE_THEAD_SHARE: u64 = 1 << 60;
pub const PTE_THEAD_BUF: u64 = 1 << 61;
pub const PTE_THEAD_CACHE: u64 = 1 << 62;
pub const PTE_THEAD_SO: u64 = 1 << 63;

const PPN_MASK: u64 = 0xFFFFFFFFFFF;

const use_thead_pte_extensions =
    @hasDecl(board_cfg, "thead_pte_extensions") and board_cfg.thead_pte_extensions;

const common_leaf_flags = PTE_A | PTE_D;
const thead_memory_flags = PTE_THEAD_SHARE | PTE_THEAD_BUF | PTE_THEAD_CACHE;
const thead_device_flags = PTE_THEAD_SHARE | PTE_THEAD_SO;

pub const kernel_flags = PTE_R | PTE_W | PTE_X;
pub const user_code_flags = PTE_R | PTE_X | PTE_U;
pub const user_data_flags = PTE_R | PTE_W | PTE_U;

pub const OnePage = [512]u64;

pub fn deviceFlags(flags: u64) u64 {
    if (comptime use_thead_pte_extensions) {
        return flags | PTE_THEAD_SO;
    }
    return flags;
}

fn effectiveLeafFlags(flags: u64) u64 {
    var result = flags | common_leaf_flags;

    if (comptime use_thead_pte_extensions) {
        if ((flags & PTE_THEAD_SO) != 0) {
            result |= PTE_G | thead_device_flags;
        } else {
            result |= thead_memory_flags;
        }
    }

    return result;
}

pub fn flagsToPerm(flags: u32) u64 {
    var perm: u64 = PTE_U; // User accessible
    if (flags & elf.PF_R != 0) perm |= PTE_R;
    if (flags & elf.PF_W != 0) perm |= PTE_W;
    if (flags & elf.PF_X != 0) perm |= PTE_X;
    return perm;
}

pub const PageTableEntry = struct {
    bits: u64,

    pub fn makePte(ppn: usize, flags: u64) PageTableEntry {
        return PageTableEntry{ .bits = @as(u64, ppn) << 10 | @as(u64, flags) };
    }

    pub fn pteToPpn(self: PageTableEntry) usize {
        return @intCast((self.bits >> 10) & PPN_MASK);
    }

    pub fn pteToPa(self: PageTableEntry) PhysicalAddress {
        return PhysicalAddress{ .addr = @intCast((self.bits & (PPN_MASK << 10)) >> 10 << 12) };
    }

    pub fn pteToFlags(self: PageTableEntry) u64 {
        return self.bits & ~(PPN_MASK << 10);
    }

    pub fn isPteValied(self: PageTableEntry) bool {
        return (self.bits & PTE_V) != 0;
    }

    pub fn isPteUser(self: PageTableEntry) bool {
        return (self.bits & PTE_U) != 0;
    }

    pub fn isPteWritable(self: PageTableEntry) bool {
        return (self.bits & PTE_W) != 0;
    }
};

pub const PageTable = struct {
    root: *[512]PageTableEntry,

    // return address of PTE in page table 'page_table'
    // that corresponds to virtual address va.
    // 'is_alloc != 0' mean create any required page-table pages.
    //
    // search or create Page Table
    // A page table contains 512 64-bit PTEs
    // and follow Sv39 spec
    //      39..63 -- must zero
    //      30..38 -- level-2 index
    //      21..29 -- level-1 index
    //      12..20 -- level-0 index
    //       0..11 -- 12 bit of byte offset in one page
    fn walkPageTable(self: *PageTable, va: VirtAddress, is_alloc: bool) ?*PageTableEntry {
        var cur_page_table = self.root;
        // NOTE: Since it relies on iterators, this reverse array use to traversal
        const levels = comptime [_]usize{ 2, 1 };

        if (va.addr >= MAX_VA)
            return null;

        for (levels) |level| {
            const vpn_idx = va.vpn(level);
            const pte = &cur_page_table[vpn_idx];

            // NOTE: .isPteValied(), compiler automatically dereferences
            if (pte.isPteValied()) {
                const next_ppn = pte.pteToPpn();
                const next_paddr = PhysicalAddress.fromPpn(next_ppn).addr;

                cur_page_table = @ptrFromInt(next_paddr);
            } else {
                if (!is_alloc) return null;

                const new_table = memory.kalloc(OnePage, 1) catch {
                    return null;
                };
                const pa = PhysicalAddress.init(@intFromPtr(new_table));
                pte.* = PageTableEntry.makePte(pa.ppn(), PTE_V);

                cur_page_table = @ptrCast(new_table);

                @memset(std.mem.asBytes(cur_page_table), 0);
            }
        }

        return &cur_page_table[va.vpn(0)];
    }

    // lookup virtAddress, return PhysicalAddress
    // 0 mean if not mapped
    // NOTE: only be used to lookup user pages.
    fn walkAddr(self: *PageTable, va: VirtAddress) !PhysicalAddress {
        if (va.addr >= MAX_VA)
            return error.InvalidAddress;

        const pte = self.walkPageTable(va, false) orelse @panic("walk page table error");

        if (!pte.isPteValied()) {
            @panic("mmap page: page table invalid");
        }

        if (!pte.isPteUser()) {
            @panic("mmap page: pagetable not user");
        }

        return pte.pteToPa();
    }

    fn mmapPage(self: *PageTable, va: VirtAddress, pa: PhysicalAddress, flags: u64) !void {
        const pte = self.walkPageTable(va, true) orelse @panic("walk page table error");

        if (pte.isPteValied()) {
            @panic("mmap page: remap");
        }

        pte.* = PageTableEntry.makePte(pa.ppn(), effectiveLeafFlags(flags) | PTE_V);
    }

    fn mmapSuperPage(self: *PageTable, va: VirtAddress, pa: PhysicalAddress, flags: u64) !void {
        if (va.addr % SUPER_PAGE_SIZE != 0 or pa.addr % SUPER_PAGE_SIZE != 0) {
            @panic("mmap super page: address not aligned");
        }
        if (va.addr >= MAX_VA) {
            return error.InvalidAddress;
        }

        const root_pte = &self.root[va.vpn(2)];
        var level_one: *[512]PageTableEntry = undefined;

        if (root_pte.isPteValied()) {
            if ((root_pte.pteToFlags() & (PTE_R | PTE_W | PTE_X)) != 0) {
                @panic("mmap super page: root leaf");
            }
            level_one = @ptrFromInt(root_pte.pteToPa().addr);
        } else {
            const page = kalloc(OnePage, 1) catch {
                return error.OutOfMemory;
            };
            level_one = @ptrCast(@alignCast(page));
            @memset(std.mem.asBytes(level_one), 0);

            const pa_root = PhysicalAddress.init(@intFromPtr(level_one));
            root_pte.* = PageTableEntry.makePte(pa_root.ppn(), PTE_V);
        }

        const leaf = &level_one[va.vpn(1)];
        if (leaf.isPteValied()) {
            @panic("mmap super page: remap");
        }

        leaf.* = PageTableEntry.makePte(pa.ppn(), effectiveLeafFlags(flags) | PTE_V);
    }

    pub fn create() !PageTable {
        const page = kalloc(OnePage, 1) catch |err| {
            return err;
        };
        const root: *[512]PageTableEntry = @ptrCast(@alignCast(page));
        @memset(std.mem.asBytes(root), 0);

        return PageTable{ .root = root };
    }

    fn freeWalk(self: *PageTable, page_table: *[512]PageTableEntry, level: usize) void {
        for (page_table, 0..) |*pte, i| {
            if (pte.isPteValied()) {
                const flags = pte.pteToFlags();

                const is_branch = (flags & (PTE_R | PTE_W | PTE_X)) == 0;

                if (is_branch and level > 0) {
                    const child_pa = pte.pteToPa();
                    const child_pt: *[512]PageTableEntry = @ptrFromInt(child_pa.addr);

                    self.freeWalk(child_pt, level - 1);

                    page_table[i] = PageTableEntry{ .bits = 0 };

                    kfree(OnePage, @ptrCast(child_pt), 1);
                } else if (pte.isPteValied() and level == 0) {
                    kprint("freeWalk: leaf PTE still valid at index {}\n", .{i});
                    @panic("freeWalk: leaf");
                }
            }
        }
    }

    pub fn freeUserMemory(self: *PageTable, sz: usize) void {
        if (sz == 0) return;

        const aligned_sz = Page.roundUp(sz);
        const npages = aligned_sz / PAGE_SIZE;

        self.unmapRange(0, npages * PAGE_SIZE, true) catch |err| {
            kprint("freeUserMemory: unmapRange failed: {}\n", .{err});
        };
    }

    pub fn freePageTable(self: *PageTable, sz: usize) void {
        self.unmapRange(address.TRAMPOLINE, PAGE_SIZE, false) catch {};

        self.unmapRange(address.TRAPFRAME, PAGE_SIZE, false) catch {};

        self.freeUserMemory(sz);

        self.freeWalk(self.root, 2);

        kfree(OnePage, @ptrCast(self.root), 1);
        self.root = undefined;
    }

    pub fn destroy(self: *PageTable, free_user_pages: bool) void {
        if (free_user_pages) {
            self.freeWalk(self.root, 2);
        }
        kfree(OnePage, @ptrCast(self.root), 1);
        self.root = undefined;
    }

    // copy from kernel to user space.
    // Copy len bytes from src to virtual address dstva in a given page table.
    pub fn copyOut(self: *PageTable, dst: VirtAddress, src: []const u8, len: usize) bool {
        var tmp_len = len;
        var va = dst;
        var src_offset: usize = 0;

        while (tmp_len > 0) {
            const va0 = va.roundDown();
            if (va0.into(usize) >= MAX_VA) {
                return false;
            }
            const page_offset = va.into(usize) - va0.into(usize);

            const pte = self.walkPageTable(va0, false) orelse @panic("unmap: walk page table error");

            if (!pte.isPteValied()) {
                @panic("unmap: not mapped");
            }

            if (!pte.isPteUser()) {
                @panic("mmap page: pagetable not user");
            }

            if (!pte.isPteWritable()) {
                @panic("mmap page: pagetable not writeable");
            }

            const pa = pte.pteToPa();

            const n = @min(PAGE_SIZE - page_offset, tmp_len);
            const dst_ptr = @as([*]u8, @ptrFromInt(pa.into(usize) + page_offset));

            @memcpy(dst_ptr[0..n], src[src_offset .. src_offset + n]);

            tmp_len -= n;
            src_offset += n;
            va = VirtAddress.init(va0.into(usize) + PAGE_SIZE);
        }

        return true;
    }

    // copy from user to kernel
    // copy string to dst from virtual address srcva in a given page table.
    // return usize for copy string len
    pub fn copyInStr(self: *PageTable, dst: []u8, src: VirtAddress) !usize {
        if (dst.len == 0) {
            return error.BufferTooSmall;
        }

        var va = src.addr;
        var desti: usize = 0;

        while (desti < dst.len) {
            const va0 = VirtAddress.init(va).roundDown();
            const pa = try self.walkAddr(va0);
            if (pa.addr == 0) {
                return error.InvalidAddress;
            }

            const offset = va - va0.addr;
            const n = PAGE_SIZE - offset;
            const src_ptr = @as([*]u8, @ptrFromInt(pa.addr + offset));

            var i: usize = 0;
            while (i < n and desti < dst.len) : (i += 1) {
                dst[desti] = src_ptr[i];

                if (src_ptr[i] == 0) {
                    return desti;
                }
                desti += 1;
            }

            va = va0.addr + PAGE_SIZE;
        }

        return error.BufferTooSmall;
    }

    // copy from user to kernel
    // Copy len bytes to dst from virtual address srcva in a given page table.
    pub fn copyIn(self: *PageTable, dst: []u8, src: VirtAddress, len: usize) bool {
        var va = src;
        var dst_offset: usize = 0;
        var remaining = len;

        while (remaining > 0) {
            const va0 = va.roundDown();
            const page_offset = va.into(usize) - va0.into(usize);

            const pa = self.walkAddr(va0) catch {
                kprint("va0 {} is not in pagetable\n", .{va0.into(usize)});
                return false;
            };
            if (pa.addr == 0) {
                return false;
            }

            const n = @min(PAGE_SIZE - page_offset, remaining);

            const src_ptr = @as([*]u8, @ptrFromInt(pa.into(usize) + page_offset));

            @memcpy(dst[dst_offset .. dst_offset + n], src_ptr[0..n]);

            remaining -= n;
            dst_offset += n;
            va = VirtAddress.init(va0.into(usize) + PAGE_SIZE);
        }

        return true;
    }

    pub fn mmapRange(self: *PageTable, va_start: usize, pa_start: usize, size: usize, flags: u64) !void {
        if (va_start % PAGE_SIZE != 0) {
            @panic("mmap range: va not aligned");
        }

        if (size == 0) {
            @panic("mappages: size");
        }

        var va = va_start;
        var pa = pa_start;
        var remaining = size;

        // Use Sv39 megapages for large, aligned identity mappings. The initial
        // DuoS kernel memory mapping is nearly 512 MiB and would otherwise
        // require over 126,000 individual 4 KiB page-table entries.
        while (remaining > 0) {
            if (va % SUPER_PAGE_SIZE == 0 and
                pa % SUPER_PAGE_SIZE == 0 and
                remaining >= SUPER_PAGE_SIZE)
            {
                try self.mmapSuperPage(
                    VirtAddress{ .addr = va },
                    PhysicalAddress{ .addr = pa },
                    flags,
                );
                va += SUPER_PAGE_SIZE;
                pa += SUPER_PAGE_SIZE;
                remaining -= SUPER_PAGE_SIZE;
            } else {
                const chunk = @min(remaining, PAGE_SIZE);

                try self.mmapPage(
                    VirtAddress{ .addr = va },
                    PhysicalAddress{ .addr = pa },
                    flags,
                );
                va += chunk;
                pa += chunk;
                remaining -= chunk;
            }
        }
    }

    pub fn unmapRange(self: *PageTable, va_start: usize, size: usize, do_free: bool) !void {
        const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

        if (va_start % PAGE_SIZE != 0) {
            @panic("unmap range: va not aligned");
        }

        for (0..pages) |i| {
            const va = VirtAddress{ .addr = va_start + i * PAGE_SIZE };

            const pte = self.walkPageTable(va, false) orelse @panic("unmap: walk page table error");

            if (!pte.isPteValied()) {
                @panic("unmap: not mapped");
            }
            if (pte.pteToFlags() == PTE_V) {
                @panic("unmap: not a leaf");
            }

            if (do_free) {
                const pa = pte.pteToPa();
                kfree(OnePage, @ptrFromInt(pa.addr), 1);
            }

            pte.* = PageTableEntry{ .bits = 0 };
        }
    }

    pub fn vmDealloc(self: *PageTable, old_size: usize, new_size: usize) !usize {
        if (new_size < old_size)
            return old_size;

        if (Page.roundUp(new_size) < Page.roundUp(old_size)) {
            const npages = (Page.roundUp(old_size) - Page.roundUp(new_size)) / PAGE_SIZE;
            try self.unmapRange(Page.roundUp(new_size), npages, true);
        }

        return new_size;
    }

    pub fn vmAlloc(self: *PageTable, old_size: usize, new_size: usize, flags: u64) !usize {
        if (new_size <= old_size)
            return old_size;

        const aligned_oldsz = Page.roundUp(old_size);
        const aligned_newsz = Page.roundUp(new_size);

        var a = aligned_oldsz;

        while (a < aligned_newsz) : (a += PAGE_SIZE) {
            const mem = kalloc(OnePage, 1) catch |err| {
                return err;
            };

            @memset(mem, 0);

            try self.mmapPage(
                VirtAddress.init(a),
                PhysicalAddress.init(@intFromPtr(mem)),
                PTE_R | PTE_U | flags,
            );
        }

        return aligned_newsz;
    }

    pub fn vmCopy(old: *PageTable, new: *PageTable, sz: u64) !void {
        var va: u64 = 0;
        while (va < sz) : (va += PAGE_SIZE) {
            const pte = walkPageTable(old, VirtAddress.init(va), false) orelse @panic("vmCopy: pte not exist\n");

            if (!pte.isPteValied()) {
                @panic("vmCopy: page not present\n");
            }

            const pa = pte.pteToPa();
            const flags = pte.pteToFlags();

            const mem = kalloc(OnePage, 1) catch |err| {
                return err;
            };
            errdefer kfree(OnePage, mem, 1);

            const src_ptr: [*]const u8 = @ptrFromInt(pa.into(usize));
            const dst_ptr: [*]u8 = @ptrCast(mem);
            @memcpy(dst_ptr[0..PAGE_SIZE], src_ptr[0..PAGE_SIZE]);

            try new.mmapRange(va, @intFromPtr(mem), PAGE_SIZE, flags);
        }

        return;
    }

    // mark a PTE invalid for user access.
    // used by exec for the user stack guard page.
    pub fn clear(self: *PageTable, va: VirtAddress) !void {
        const pte = self.walkPageTable(va, false) orelse return error.walkError;
        const old_bits = pte.bits;
        const new_bits = old_bits & ~@as(u64, PTE_U);
        pte.bits = new_bits;
    }
};
