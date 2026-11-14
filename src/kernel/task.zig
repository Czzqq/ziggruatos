const std = @import("std");

const arch = @import("arch");
const riscv = arch.riscv;
const io = arch.io;
const sbi = arch.sbi;
const spinlock = arch.spinlock;

const max_cpus = @import("board").config.max_cpus;
const boot_trace = @import("board").config.boot_trace;

const memory = @import("memory.zig");
const trap = @import("trap.zig");
const pagetable = @import("pagetable.zig");
const initramfs = @import("fs").initramfs;
const vfs = @import("fs").vfs;

const address = @import("common").address;
const elf = @import("common").elf;

const Page = address.Page;
const VirtAddress = address.VirtAddress;
const PhysicalAddress = address.PhysicalAddress;

const PageTable = pagetable.PageTable;
const OnePage = pagetable.OnePage;

const TRAMPOLINE = address.TRAMPOLINE;
const TRAPFRAME = address.TRAPFRAME;
const PAGE_SIZE = address.PAGE_SIZE;

const MAXARG = @import("syscall.zig").MAXARG;

const PerCpu = arch.cpu.PerCpu;
const SpinLock = spinlock.SpinLock;
const trapFrame = @import("trap.zig").trapFrame;

const kprint = @import("common").utils.kprint;

fn bootTrace(comptime message: []const u8) void {
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

pub const processState = enum {
    ready,
    running,
    block,
    terminated,
    sleeping,
    zombie,
};

const Priority = u8;

const Context = struct {
    ra: u64,
    sp: u64,

    s0: u64,
    s1: u64,
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
};

const Slot = struct {
    var slot_bitmap: [64]u8 = @splat(0);
    var lock: SpinLock = SpinLock.init("kernel_stack_slots");

    const SLOTS_PER_WORD: usize = 8;
    const SLOT_CAPACITY: usize = slot_bitmap.len * SLOTS_PER_WORD;

    fn allocFreeSlot() !usize {
        lock.acquire();
        defer lock.release();
        for (&slot_bitmap, 0..) |*word, wi| {
            if (word.* != 0xFF) {
                const free_mask: u8 = ~word.*;
                const bit_index_u8: u8 = @ctz(free_mask);
                const bit_index: u3 = @intCast(bit_index_u8);

                const slot = wi * SLOTS_PER_WORD + bit_index;
                if (slot >= SLOT_CAPACITY)
                    break;

                word.* |= (@as(u8, 1) << bit_index);
                return slot;
            }
        }
        return error.OutOfSlots;
    }

    fn freeSlot(slot: usize) void {
        lock.acquire();
        defer lock.release();
        if (slot >= SLOT_CAPACITY) return;

        const wi = slot / SLOTS_PER_WORD;
        const bi_raw = slot % SLOTS_PER_WORD;
        const bi: u3 = @intCast(bi_raw);

        slot_bitmap[wi] &= ~(@as(u8, 1) << bi);
    }
};

pub const TaskCpu = struct {
    current: ?*taskControlBlock,
    context: Context,

    var task_cpus: [max_cpus]TaskCpu = undefined;

    pub fn byId(cpuid: u64) *TaskCpu {
        return @ptrCast(&task_cpus[cpuid]);
    }

    pub fn currentTaskCpu() ?*TaskCpu {
        return byId(PerCpu.getId());
    }

    pub fn currentTcb() ?*taskControlBlock {
        spinlock.pushoff();
        const tcb = currentTaskCpu().?.current;
        spinlock.popoff();

        return tcb;
    }
};

const USERSTACK = 4;
extern fn trampoline() callconv(.naked) void;
pub const taskControlBlock = struct {
    pid: usize,

    p_pid: usize, // parent pid
    parent: *taskControlBlock, // parent task

    lock: SpinLock,

    state: processState,
    killed: bool,
    xstate: i32, // Exit status to be returned to parent's wait
    trapframe: *trapFrame,
    context: Context,
    pagetable: PageTable,
    kstack: u64, // Virtual address of kernel stack
    kstack_slot: u64, // slot
    sz: usize, // Size of process memory (bytes)

    name: [32]u8,
    priority: Priority,
    chan: usize, // sleep channel(wait tcb pid)

    // file
    files: [vfs.MAX_FD]?*vfs.File = @splat(null),

    // current working directory
    cwd: ?*vfs.Dentry = null,

    /// Allocate a free file descriptor for this process
    pub fn alloc_fd(self: *taskControlBlock) !usize {
        for (self.files, 0..) |maybe_file, i| {
            if (maybe_file == null) {
                return i;
            }
        }
        return error.TooManyOpenFiles;
    }

    /// Open a file for this process
    pub fn fileOpen(self: *taskControlBlock, path: []const u8, flags: u32) !usize {
        const access_mode = flags & vfs.O_ACCMODE;
        const vfs_flags: vfs.OpenFlags = .{
            .read = access_mode == vfs.O_RDONLY or access_mode == vfs.O_RDWR,
            .write = access_mode == vfs.O_WRONLY or access_mode == vfs.O_RDWR,
            .create = flags & vfs.O_CREAT != 0,
            .truncate = flags & vfs.O_TRUNC != 0,
            .append = flags & vfs.O_APPEND != 0,
            .directory = flags & vfs.O_DIRECTORY != 0,
        };

        const file = try vfs.get_vfs().open(path, vfs_flags, self.cwd);
        const fd = try self.alloc_fd();
        self.files[fd] = file;
        return fd;
    }

    /// Read from an open file
    pub fn fileRead(self: *taskControlBlock, fd: usize, buffer: []u8) !usize {
        if (fd >= vfs.MAX_FD or self.files[fd] == null) {
            return error.BadFileDescriptor;
        }

        const file = self.files[fd].?;
        if (!file.flags.read) {
            return error.PermissionDenied;
        }

        const bytes_read = try file.read(buffer);
        file.offset += bytes_read;
        return bytes_read;
    }

    // /// Write to an open file
    pub fn fileWrite(self: *taskControlBlock, fd: usize, buffer: []const u8) !usize {
        if (fd >= vfs.MAX_FD or self.files[fd] == null) {
            return error.BadFileDescriptor;
        }

        const file = self.files[fd].?;
        if (!file.flags.write) {
            return error.PermissionDenied;
        }

        const bytes_written = try file.write(buffer);
        file.offset += bytes_written;
        return bytes_written;
    }

    /// Close an open file
    pub fn fileClose(self: *taskControlBlock, fd: usize) !void {
        if (fd >= vfs.MAX_FD or self.files[fd] == null) {
            return error.BadFileDescriptor;
        }

        const file = self.files[fd].?;
        // Clear the file pointer immediately
        self.files[fd] = null;

        // Decrement reference count
        file.ref_count -= 1;

        // Destroy the file only if reference count reaches 0
        if (file.ref_count == 0) {
            vfs.get_vfs().allocator.destroy(file);
        }
    }

    const KStackAllocResult = struct {
        va: usize,
        slot: usize,
        pa: usize,
        size: usize,
    };

    fn printInfo(self: *const taskControlBlock) void {
        kprint("PID: {}, Name: {}, Parent PID: {}, state: {}, priority: {}\n", self.pid, self.name, self.p_pid, self.priority);
    }

    pub const KSTACK_PAGES = 8; // 32KB for each process kernal stack
    var kstack_map_lock: SpinLock = SpinLock.init("kernel_stack_map");
    // calculate process kernal stack va in kernel_pagetable
    pub fn kstackVa(p: usize) usize {
        // [ guard page ] [ 32k kstack]
        return TRAMPOLINE - ((p + 1) * (KSTACK_PAGES + 1) * PAGE_SIZE);
    }

    fn kstackAlloc() !KStackAllocResult {
        var kpgtbl = memory.getKernelPageTable() orelse {
            return error.EmptyKernelPagetable;
        };

        const page_ptr = try memory.kalloc(OnePage, KSTACK_PAGES);
        errdefer memory.kfree(OnePage, page_ptr, KSTACK_PAGES);

        @memset(std.mem.asBytes(page_ptr), 0);

        const pa = @intFromPtr(page_ptr);
        const slot = try Slot.allocFreeSlot();
        errdefer Slot.freeSlot(slot);

        const va = kstackVa(slot);

        kstack_map_lock.acquire();
        defer kstack_map_lock.release();
        try kpgtbl.mmapRange(
            va,
            pa,
            PAGE_SIZE * KSTACK_PAGES,
            pagetable.PTE_R | pagetable.PTE_W,
        );

        return .{
            .va = va,
            .slot = slot,
            .pa = pa,
            .size = PAGE_SIZE * KSTACK_PAGES,
        };
    }

    fn kstackFree(
        slot: usize,
        va: usize,
    ) !void {
        var kpgtbl = memory.getKernelPageTable() orelse {
            return error.EmptyKernelPagetable;
        };
        kstack_map_lock.acquire();
        defer kstack_map_lock.release();
        try kpgtbl.unmapRange(va, PAGE_SIZE * KSTACK_PAGES, true);

        Slot.freeSlot(slot);

        memory.sfenceVma();
    }

    pub fn alloc(pid: u32, name: []const u8, priority: Priority) !taskControlBlock {
        bootTrace("T: tcb alloc enter\n");
        const trapframe_ptr = try memory.kalloc(trapFrame, 1);
        errdefer memory.kfree(trapFrame, trapframe_ptr, 1);
        @memset(std.mem.asBytes(trapframe_ptr), 0);
        bootTrace("T: trapframe allocated\n");

        var pgtbl = try PageTable.create();
        errdefer pgtbl.destroy(false);
        bootTrace("T: user root page table allocated\n");

        const ks = try kstackAlloc();
        errdefer kstackFree(ks.slot, ks.va) catch {};
        bootTrace("T: kernel stack allocated\n");

        try pgtbl.mmapRange(TRAMPOLINE, @intFromPtr(&trampoline), PAGE_SIZE, pagetable.PTE_R | pagetable.PTE_X);
        errdefer pgtbl.unmapRange(TRAMPOLINE, PAGE_SIZE, false) catch
            @panic("userinit: unmap trampoline failed");
        bootTrace("T: trampoline mapped\n");

        try pgtbl.mmapRange(TRAPFRAME, @intFromPtr(trapframe_ptr), PAGE_SIZE, pagetable.PTE_R | pagetable.PTE_W);
        errdefer pgtbl.unmapRange(TRAPFRAME, PAGE_SIZE, false);
        bootTrace("T: trapframe mapped\n");

        var tcb = taskControlBlock{
            .pid = pid,
            .p_pid = undefined,
            .parent = undefined,
            .lock = SpinLock.init("proc"),
            .state = processState.ready,
            .name = undefined,
            .killed = false,
            .xstate = 0,
            .kstack = ks.va,
            .kstack_slot = ks.slot,
            .sz = undefined,
            .trapframe = trapframe_ptr,
            .context = undefined,
            .pagetable = pgtbl,
            .priority = priority,
            .chan = 0,
        };

        // Initialize CWD to root directory
        const v = vfs.get_vfs();
        tcb.cwd = v.root_dentry;
        tcb.cwd.?.ref_count += 1;

        @memset(@as([*]u8, @ptrCast(&tcb.context))[0..@sizeOf(Context)], 0);

        tcb.context.ra = @intFromPtr(&proc.forkret);
        tcb.context.sp = tcb.kstack + ks.size; // set sp to kstack top

        const len = @min(name.len, 31);
        @memcpy(tcb.name[0..len], name[0..len]);

        bootTrace("T: tcb alloc done\n");
        return tcb;
    }

    // free alloc and mmap resource when exit
    pub fn free(self: *taskControlBlock) !void {
        try self.pagetable.unmapRange(TRAPFRAME, address.PAGE_SIZE, false);

        try self.pagetable.unmapRange(TRAMPOLINE, address.PAGE_SIZE, false);

        try self.pagetable.unmapRange(0, address.PAGE_SIZE, false);

        self.pagetable.destroy(false);

        memory.kfree(trapFrame, self.trapframe, 1);

        try kstackFree(self.kstack_slot, self.kstack);
    }

    pub fn isKilled(self: *const taskControlBlock) bool {
        return self.killed;
    }

    fn commitExec(self: *taskControlBlock, new_pt: PageTable, sz: usize, entry: u64, sp: u64, argc: usize) void {
        bootTrace("T: commitExec enter\n");
        var old_pt = self.pagetable;
        const old_sz = self.sz;

        // construct new pagetable and trapframe
        self.pagetable = new_pt;
        self.sz = sz;
        self.trapframe.sepc = entry; // set program counter to entry address
        self.trapframe.sp = sp; // set sp
        self.trapframe.a0 = argc; // argc to main(argc, argv)
        self.trapframe.a1 = sp; // argv to main(argc, argv)

        old_pt.freePageTable(old_sz);
        if (comptime boot_trace) {
            bootTrace("T: commitExec done entry=");
            bootTraceHex(entry);
            bootTrace(" sp=");
            bootTraceHex(sp);
            bootTrace("\n");
        }
    }

    fn execFromMem(self: *taskControlBlock, elf_data: []const u8, argv: [][]u8) !u64 {
        bootTrace("T: execFromMem enter\n");
        var elf_header: elf.ElfHeader = undefined;

        var sz: usize = 0;
        var new_pt: PageTable = undefined;

        if (argv.len > MAXARG) {
            kprint("!!! Too many args: {} > {}\n", .{ argv.len, MAXARG });
            return error.TooManyArguments;
        }

        @memcpy(std.mem.asBytes(&elf_header), elf_data[0..@sizeOf(elf.ElfHeader)]);
        bootTrace("T: execFromMem elf header copied\n");
        if (elf_data.len < @sizeOf(elf.ElfHeader)) {
            kprint("!!! ELF too small: {} < {}\n", .{ elf_data.len, @sizeOf(elf.ElfHeader) });
            return error.ElfTooSmall;
        }

        if (elf_header.magic != elf.ELF_MAGIC) {
            return error.InvalidMagic;
        }
        bootTrace("T: execFromMem elf magic ok\n");

        // alloc new task pagetable
        new_pt = try PageTable.create();
        bootTrace("T: execFromMem page table created\n");

        // catch when error
        var cleanup_flags = struct {
            trampoline: bool = false,
            trapframe: bool = false,
            user_mem: bool = false,
        }{};

        errdefer {
            if (cleanup_flags.trampoline) {
                new_pt.unmapRange(TRAMPOLINE, PAGE_SIZE, false) catch {};
            }
            if (cleanup_flags.trapframe) {
                new_pt.unmapRange(TRAPFRAME, PAGE_SIZE, false) catch {};
            }
            if (cleanup_flags.user_mem) {
                new_pt.freeUserMemory(sz);
            }
            new_pt.destroy(false);
        }

        try new_pt.mmapRange(TRAMPOLINE, @intFromPtr(&trampoline), PAGE_SIZE, pagetable.PTE_R | pagetable.PTE_X);
        cleanup_flags.trampoline = true;
        bootTrace("T: execFromMem trampoline mapped\n");

        try new_pt.mmapRange(TRAPFRAME, @intFromPtr(self.trapframe), PAGE_SIZE, pagetable.PTE_R | pagetable.PTE_W);

        cleanup_flags.trapframe = true;
        bootTrace("T: execFromMem trapframe mapped\n");

        // load program into memory
        for (0..elf_header.phnum) |i| {
            const off = elf_header.phoff + i * @sizeOf(elf.ProgHeader);
            var ph: elf.ProgHeader = undefined;

            @memcpy(std.mem.asBytes(&ph), elf_data[off .. off + @sizeOf(elf.ProgHeader)]);

            if (ph.type != elf.PT_LOAD)
                continue;

            if (ph.memsz < ph.filesz)
                return error.InvalidSize;
            if (ph.vaddr + ph.memsz < ph.vaddr)
                return error.InvalidAddress;
            if (ph.vaddr % PAGE_SIZE != 0)
                return error.UnalignedAddress;

            const sz1 = try new_pt.vmAlloc(sz, ph.vaddr + ph.memsz, pagetable.flagsToPerm(ph.flags) | pagetable.PTE_W);
            cleanup_flags.user_mem = true;

            sz = sz1;
            if (comptime boot_trace) {
                bootTrace("T: execFromMem segment vaddr=");
                bootTraceHex(ph.vaddr);
                bootTrace(" filesz=");
                bootTraceHex(ph.filesz);
                bootTrace(" memsz=");
                bootTraceHex(ph.memsz);
                bootTrace("\n");
            }

            if (ph.filesz > 0) {
                const segment_data = elf_data[ph.off..][0..ph.filesz];

                if (new_pt.copyOut(VirtAddress.init(ph.vaddr), segment_data, ph.filesz) == false) {}
            }
        }

        sz = std.mem.alignForward(u64, sz, PAGE_SIZE);
        const stack_pages = (USERSTACK + 1) * PAGE_SIZE;
        sz = try new_pt.vmAlloc(sz, sz + stack_pages, pagetable.PTE_W);
        bootTrace("T: execFromMem stack allocated\n");

        try new_pt.clear(VirtAddress.init(sz - stack_pages));
        bootTrace("T: execFromMem stack cleared\n");

        const stackbase = sz - USERSTACK * PAGE_SIZE;
        var sp = sz;
        var ustack: [MAXARG + 1]u64 = undefined;

        const ustack_as_bytes = std.mem.asBytes(&ustack);

        if (argv.len > MAXARG) return error.TooManyArguments;

        for (argv, 0..) |arg, i| {
            sp -= arg.len + 1;
            sp = std.mem.alignBackward(u64, sp, 16); // RISC-V ABI 16 bytes align

            if (sp < stackbase) return error.StackOverflow;

            if (new_pt.copyOut(VirtAddress.init(sp), arg, arg.len) == false) {
                return error.copyOutFailed;
            }

            const null_byte = [_]u8{0};
            if (new_pt.copyOut(VirtAddress.init(sp + arg.len), &null_byte, 1) == false) {
                return error.copyOutFailed;
            }

            ustack[i] = sp;
        }
        ustack[argv.len] = 0;

        const ptr_array_size = (argv.len + 1) * @sizeOf(u64);
        sp -= ptr_array_size;
        sp = std.mem.alignBackward(u64, sp, 16);

        if (sp < stackbase) return error.StackOverflow;

        const ustack_bytes = ustack_as_bytes[0..ptr_array_size];

        if (new_pt.copyOut(VirtAddress.init(sp), ustack_bytes, ptr_array_size) == false) {
            return error.copyOutFailed;
        }
        bootTrace("T: execFromMem argv copied\n");

        self.commitExec(new_pt, sz, elf_header.entry, sp, argv.len);
        bootTrace("T: execFromMem commit complete\n");

        return argv.len;
    }
};

const taskNode = struct {
    tcb: taskControlBlock,
    next: ?*taskNode,
    prev: ?*taskNode,
};

const taskList = struct {
    head: ?*taskNode = null,
    tail: ?*taskNode = null,
    count: u32 = 0,

    last_scheduled: ?*taskNode,

    pub fn init() taskList {
        return taskList{
            .head = null,
            .tail = null,
            .count = 0,
            .last_scheduled = null,
        };
    }

    // tail insert
    pub fn addTask(self: *taskList, tcb: taskControlBlock) !*taskNode {
        const node = memory.kalloc(taskNode, 1) catch |err| {
            kprint("alloc failed: {}\n", .{});
            return err;
        };
        @memset(std.mem.asBytes(node), 0);

        node.* = taskNode{
            .tcb = tcb,
            .next = null,
            .prev = self.tail,
        };

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }

        self.tail = node;
        self.count += 1;

        return node;
    }

    pub fn findReadTask(self: *taskList) ?*taskNode {
        if (self.head == null) return null;

        var start: ?*taskNode = null;
        if (self.last_scheduled) |last| {
            start = last.next orelse self.head;
        } else {
            start = self.head;
        }

        var current = start;
        var checked: usize = 0;

        while (checked < self.count) : (checked += 1) {
            if (current) |node| {
                if (node.tcb.state == processState.ready) {
                    self.last_scheduled = node;
                    return node;
                }

                current = node.next orelse self.head;
            } else {
                break;
            }
        }
        return null;
    }

    pub fn findByPid(self: *taskList, pid: usize) ?*taskNode {
        var cur = self.head;

        while (cur) |node| {
            if (node.tcb.pid == pid)
                return node;
            cur = node.next;
        }

        return null;
    }

    pub fn deleteByPid(self: *taskList, pid: usize) bool {
        if (self.findByPid(pid)) |node| {
            if (self.last_scheduled == node) {
                self.last_scheduled = node.prev;
            }
            // update 'prev.next' of current node
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            //update 'next.'
            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            memory.kfree(taskNode, node, 1);
            self.count -= 1;

            return true;
        }

        return false;
    }

    pub fn updateTaskState(self: *taskList, pid: u32, state: processState) bool {
        if (self.findByPid(pid)) |node| {
            node.tcb.state = state;
            return true;
        }

        return false;
    }
};

// use to lead first section 'user init code'
const initcode = [_]u8{
    0x17, 0x05, 0x00, 0x00, // auipc a0,0x0
    0x13, 0x05, 0x45, 0x02, // addi  a0,a0,36
    0x97, 0x05, 0x00, 0x00, // auipc a1,0x0
    0x93, 0x85, 0x35, 0x02, // addi  a1,a1,35
    0x93, 0x08, 0x70, 0x00, // addi  a7,zero,7
    0x73, 0x00, 0x00, 0x00, // ecall
    0x93, 0x08, 0x20, 0x00, // addi  a7,zero,2
    0x73, 0x00, 0x00, 0x00, // ecall
    0xef, 0xf0, 0x9f, 0xff, // jal   -1
    0x2f, 0x69, 0x6e, 0x69, // /ini
    0x74, 0x00, 0x00, 0x24, // t...$
    0x00, 0x00, 0x00, 0x00, // ....
    0x00, 0x00, 0x00, 0x00, // ....
};

pub const proc = struct {
    var wait_lock: SpinLock = SpinLock.init("wait");
    var task_list_lock: SpinLock = SpinLock.init("task_list");

    var task_list: taskList = taskList.init();

    var next_pid: u32 = 1;
    var init_proc: ?*taskNode = null;

    fn newPid() u32 {
        return @atomicRmw(u32, &next_pid, .Add, 1, .monotonic) + 1;
    }

    pub fn userinit() void {
        bootTrace("T: userinit enter\n");
        var tcb = taskControlBlock.alloc(next_pid, "init_proc", 255) catch {
            @panic("oom\n");
        };
        errdefer tcb.free() catch {};

        const init_node = task_list.addTask(tcb) catch {
            @panic("oom\n");
        };

        init_proc = init_node;

        var t = &init_node.tcb;

        const mem = memory.kalloc(OnePage, 1) catch {
            @panic("oom\n");
        };
        errdefer memory.kfree(OnePage, mem, 1);

        @memset(mem, 0);

        const mem_addr = @intFromPtr(mem.ptr);

        const bytes = std.mem.sliceAsBytes(mem);
        @memset(bytes, 0);
        @memcpy(bytes[0..initcode.len], &initcode);

        t.pagetable.mmapRange(0, mem_addr, PAGE_SIZE, pagetable.PTE_R | pagetable.PTE_W | pagetable.PTE_X | pagetable.PTE_U) catch {
            @panic("mmap 0 va err\n");
        };
        errdefer t.pagetable.unmapRange(0, PAGE_SIZE, false);
        bootTrace("T: init code mapped\n");

        t.sz = PAGE_SIZE;

        // prepare for the very first "return" from kernel to user.
        t.trapframe.sepc = 0; // user program counter
        t.trapframe.sp = PAGE_SIZE; // user stack pointer

        t.state = processState.ready;

        _ = PerCpu.alloc(0) catch {
            @panic("percpu alloc failed\n");
        };
        riscv.riscvWriteTp(0);
        bootTrace("T: userinit done\n");
    }

    pub fn sleep(chan: usize, lock: *SpinLock) void {
        const t = TaskCpu.currentTcb().?;

        t.lock.acquire();
        lock.release();

        t.chan = chan;
        t.state = processState.sleeping;

        sched();

        t.chan = 0;

        t.lock.release();
        lock.acquire();
    }

    // Wait for a child process to exit and return its pid.
    // Return -1 if this process has no children.
    pub fn wait(addr: u64) u64 {
        const t = TaskCpu.currentTcb().?;

        wait_lock.acquire();

        while (true) {
            task_list_lock.acquire();
            var cur = task_list.head;
            var have_kids = false;

            while (cur) |node| {
                // find current tcb child task
                if (node.tcb.p_pid == t.pid) {
                    node.tcb.lock.acquire();

                    have_kids = true;
                    // recover zombie childs
                    if (node.tcb.state == processState.zombie) {
                        // found
                        var tcb = node.tcb;
                        const pid = tcb.pid;
                        if (addr != 0 and
                            t.pagetable.copyOut(VirtAddress.init(addr), std.mem.asBytes(&node.tcb.xstate), @sizeOf(i32)) == false)
                        {
                            node.tcb.lock.release();
                            task_list_lock.release();
                            wait_lock.release();
                            return @bitCast(@as(i64, -1));
                        }

                        tcb.free() catch {
                            node.tcb.lock.release();
                            task_list_lock.release();
                            wait_lock.release();
                            return @bitCast(@as(i64, -1));
                        };

                        node.tcb.lock.release();
                        // The list lock keeps scheduler and wakeup from using this node.
                        _ = task_list.deleteByPid(pid);
                        task_list_lock.release();
                        wait_lock.release();

                        return @intCast(pid);
                    }

                    node.tcb.lock.release();
                }

                cur = node.next;
            }

            // No point waiting if we don't have any children.
            if (!have_kids or t.isKilled()) {
                task_list_lock.release();
                wait_lock.release();
                return @bitCast(@as(i64, -1));
            }

            task_list_lock.release();
            sleep(t.pid, &wait_lock);
        }
    }

    pub fn fork() u64 {
        const t = TaskCpu.currentTcb().?;

        var new_t = taskControlBlock.alloc(newPid(), &t.name, 255) catch |err| {
            kprint("alloc tcb failed with {}\n", .{err});
            @panic("");
        };
        errdefer new_t.free() catch {
            @panic("free new_t failed\n");
        };

        PageTable.vmCopy(&t.pagetable, &new_t.pagetable, t.sz) catch {
            return @bitCast(@as(i64, -1));
        };

        new_t.sz = t.sz;

        // Copy opened files with reference count increment
        for (0..vfs.MAX_FD) |i| {
            if (t.files[i]) |file| {
                // Increment reference count
                file.ref_count += 1;
                // Copy file pointer to new process
                new_t.files[i] = file;
            } else {
                new_t.files[i] = null;
            }
        }

        // Copy CWD - decrement the one set by alloc(), then copy parent's
        if (new_t.cwd) |cwd| {
            cwd.ref_count -= 1;
        }
        new_t.cwd = t.cwd;
        if (new_t.cwd) |cwd| {
            cwd.ref_count += 1;
        }

        const src_ptr: [*]const u8 = @ptrCast(t.trapframe);
        const dst_ptr: [*]u8 = @ptrCast(new_t.trapframe);
        @memcpy(dst_ptr[0..PAGE_SIZE], src_ptr[0..PAGE_SIZE]);

        wait_lock.acquire();
        new_t.p_pid = t.pid;
        new_t.parent = t;
        wait_lock.release();

        new_t.lock.acquire();
        // Cause fork to return 0 in the child.
        new_t.trapframe.a0 = 0;
        new_t.state = processState.ready;
        new_t.lock.release();

        task_list_lock.acquire();
        defer task_list_lock.release();
        _ = proc.task_list.addTask(new_t) catch {
            return @bitCast(@as(i64, -1));
        };

        return new_t.pid;
    }

    extern fn swtch(old: *Context, new: *Context) void;
    pub fn scheduler() void {
        bootTrace("T: scheduler enter\n");
        var cur_task_cpu = TaskCpu.currentTaskCpu().?;
        while (true) {
            // Keep interrupts disabled until the first task is fully selected.
            // On C906, an already-pending timer interrupt can otherwise arrive
            // before TaskCpu.current is initialized.
            riscv.archLocalIrqDisable();
            task_list_lock.acquire();
            if (task_list.findReadTask()) |node| {
                bootTrace("T: scheduler selected task\n");
                node.tcb.lock.acquire();
                node.tcb.state = processState.running;
                cur_task_cpu.current = &node.tcb;

                task_list_lock.release();

                bootTrace("T: scheduler before swtch\n");
                swtch(&cur_task_cpu.context, &node.tcb.context);
                bootTrace("T: scheduler after swtch\n");
                cur_task_cpu.current = null;
                node.tcb.lock.release();
            } else {
                task_list_lock.release();
                cur_task_cpu.current = null;
                riscv.archLocalIrqEnable();
                asm volatile ("wfi");
            }
        }
    }

    pub fn reparent(tcb: *taskControlBlock) void {
        task_list_lock.acquire();
        var cur = task_list.head;
        var found = false;
        while (cur) |node| {
            if (node.tcb.p_pid == tcb.pid) {
                node.tcb.parent = &(init_proc.?.tcb);
                node.tcb.p_pid = init_proc.?.tcb.pid;
                found = true;
            }
            cur = node.next;
        }
        task_list_lock.release();
        if (found) wakeup(init_proc.?.tcb.pid);
    }

    pub fn sched() void {
        const cpu = PerCpu.currentCpu();
        const t = TaskCpu.currentTcb().?;

        if (!t.lock.holding()) {
            @panic("sched: not holding task lock");
        }

        if (cpu.noff != 1) {
            @panic("sched: locks held");
        }

        if (t.state == processState.running)
            @panic("sched running\n");

        if (io.readCsr("sstatus") & riscv.SR_SIE != 0) {
            @panic("sched interruptiable\n");
        }

        const intena = cpu.intena;
        swtch(&t.context, &TaskCpu.currentTaskCpu().?.context);
        PerCpu.currentCpu().intena = intena;
    }

    pub fn yield() void {
        var t = TaskCpu.currentTcb().?;

        t.lock.acquire();
        t.state = processState.ready;
        sched();
        t.lock.release();
    }

    // caller holding proc_lock
    pub fn wakeup(channel: usize) void {
        task_list_lock.acquire();
        defer task_list_lock.release();
        var idx = task_list.head;

        // there no task on cpu process
        const cur_tcb = TaskCpu.currentTcb() orelse null;

        while (idx) |node| {
            if (&node.tcb != cur_tcb) {
                node.tcb.lock.acquire();
                if (node.tcb.state == processState.sleeping and
                    node.tcb.chan == channel)
                {
                    node.tcb.state = processState.ready;
                }
                node.tcb.lock.release();
            }
            idx = node.next;
        }
    }

    pub fn exec(path: []u8, argv: [][]u8) u64 {
        bootTrace("T: exec enter\n");
        var t = TaskCpu.currentTcb().?;

        // if (initramfs.findFile(path)) |file_entry| {
        //     const argc = t.execFromMem(file_entry.data, argv) catch |err| {
        //         kprint("execFromMem error: {}\n", .{err});
        //         return @bitCast(@as(i64, -1));
        //     };
        //     return argc;
        // }

        const vfs_flags: vfs.OpenFlags = .{
            .read = true,
        };

        const file_state = vfs.get_vfs().stat(path) catch |err| {
            kprint("vfs state error: {}\n", .{err});
            return @bitCast(@as(i64, -1));
        };
        if (comptime boot_trace) {
            bootTrace("T: exec stat size=");
            bootTraceHex(file_state.size);
            bootTrace("\n");
        }
        const page_count = (file_state.size + PAGE_SIZE - 1) / PAGE_SIZE;

        const file_data_ptr = memory.kalloc(OnePage, page_count) catch |err| {
            kprint("kalloc failed: {}\n", .{err});
            return @bitCast(@as(i64, -1));
        };
        bootTrace("T: exec buffer allocated\n");
        defer memory.kfree(OnePage, file_data_ptr, page_count);

        const file_data = @as([*]u8, @ptrCast(file_data_ptr))[0..file_state.size];

        const file = vfs.get_vfs().open(path, vfs_flags, t.cwd) catch |err| {
            kprint("vfs open error: {}\n", .{err});
            return @bitCast(@as(i64, -1));
        };
        bootTrace("T: exec file opened\n");
        defer vfs.get_vfs().allocator.destroy(file);

        var read_bytes: usize = 0;
        while (read_bytes < file_state.size) {
            file.seek(read_bytes);
            const tmp = file.read(file_data[read_bytes..]) catch |err| {
                kprint("vfs file read error: {}\n", .{err});
                return @bitCast(@as(i64, -1));
            };
            if (tmp == 0) break;
            read_bytes += tmp;
        }

        if (read_bytes != file_state.size) {
            kprint("file read fail size, except {} acutal {}\n", .{ file_state.size, read_bytes });
            return @bitCast(@as(i64, -1));
        }
        if (comptime boot_trace) {
            bootTrace("T: exec file read bytes=");
            bootTraceHex(read_bytes);
            bootTrace("\n");
        }

        const argc = t.execFromMem(file_data, argv) catch |err| {
            kprint("execFromMem error: {}\n", .{err});
            return @bitCast(@as(i64, -1));
        };
        bootTrace("T: exec complete\n");

        return argc;
    }

    pub fn exit(xstate: i32) void {
        var t = TaskCpu.currentTcb().?;

        if (t.pid == 1) {
            @panic("init exiting");
        }

        // Close all opened files
        for (&t.files, 0..) |*file_opt, idx| {
            if (file_opt.*) |file| {
                _ = file;
                t.fileClose(idx) catch |err| {
                    kprint("fileClose failed {} on exit\n", .{err});
                };
            }
        }

        // Release CWD reference
        if (t.cwd) |cwd| {
            cwd.ref_count -= 1;
            t.cwd = null;
        }

        kprint("Process {} became zombie\n", .{t.pid});

        wait_lock.acquire();

        // give any children to init proc
        proc.reparent(t);

        // parent might be sleeping in wait()
        proc.wakeup(t.p_pid);

        t.lock.acquire();

        t.xstate = xstate;
        t.state = processState.zombie;

        wait_lock.release();

        // jump to scheduler, never to return
        proc.sched();

        @panic("zombie exit");
    }

    // A fork child's very first scheduling by scheduler()
    // will swtch to forkret.
    pub fn forkret() void {
        bootTrace("T: forkret enter\n");
        // still hold proc_lock when scheduler
        TaskCpu.currentTcb().?.lock.release();

        bootTrace("T: forkret before usertrapret\n");
        trap.usertrapret();
        bootTrace("T: forkret after usertrapret\n");
    }

    pub fn kill(pid: u32) void {
        task_list_lock.acquire();
        const t = &task_list.findByPid(pid).?.tcb;

        t.*.lock.acquire();
        task_list_lock.release();
        defer t.*.lock.release();

        t.*.killed = true;
        if (t.*.state == processState.sleeping) {
            t.*.state = processState.ready;
        }
    }
};
