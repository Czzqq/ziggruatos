pub const ELF_MAGIC: u32 = 0x464C457F;

pub const ElfHeader = extern struct {
    magic: u32,
    elf: [12]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64, // program header offset
    shoff: u64, // section header offset
    flags: u32,
    ehsize: u16,
    phentsize: u16, // program header entry size
    phnum: u16, // program header number
    shentsize: u16,
    shentnum: u16,
    shstrndx: u16,
};

pub const ProgHeader = extern struct {
    type: u32,
    flags: u32,
    off: u64, // File offset
    vaddr: u64, // Virtual address
    paddr: u64, // Physical address
    filesz: u64, // Size in file
    memsz: u64, // Size in memory
    alignment: u64,
};

// program header type
pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;

// program header flags
pub const PF_X: u32 = 1; // executable
pub const PF_W: u32 = 2; // writable
pub const PF_R: u32 = 4; // readable
