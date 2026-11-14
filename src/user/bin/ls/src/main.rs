#![no_std]
#![no_main]

use ziggurat_core::*;

fn align_up(val: usize, align: usize) -> usize {
    (val + align - 1) & !(align - 1)
}

fn read_u32(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
    ])
}

fn read_u64(buf: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
        buf[offset + 4],
        buf[offset + 5],
        buf[offset + 6],
        buf[offset + 7],
    ])
}

fn ls(path: &str) {
    // Allocate a buffer for the directory entries
    let mut buf = [0u8; 4096];

    // Call readdir syscall
    let bytes_read = syscall_readdir(path, &mut buf);

    if bytes_read <= 0 {
        println!("Failed to read directory");
        return;
    }

    // Deserialize the entries
    let mut offset: usize = 0;

    // Read number of entries
    let num_entries = read_u32(&buf, offset);
    offset += core::mem::size_of::<u32>();

    println!("{}:", path);

    for _ in 0..num_entries {
        // Read file type
        let _file_type_raw = read_u32(&buf, offset);
        offset += core::mem::size_of::<u32>();

        // Read inode ID (skip for now)
        let _inode_id = read_u64(&buf, offset);
        offset += core::mem::size_of::<u64>();

        // Read string length
        let name_len = read_u32(&buf, offset) as usize;
        offset += core::mem::size_of::<u32>();

        // Read string
        let name_slice = &buf[offset..offset + name_len];
        offset += name_len;

        // Skip padding to align to 8 bytes
        offset = align_up(offset, 8);

        // Convert to string
        if let Ok(name) = core::str::from_utf8(name_slice) {
            println!("{}", name);
        }
    }
}

fn is_option(arg: &str) -> bool {
    arg.starts_with('-')
}

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) {
    if argc < 2 {
        // No arguments, list current directory
        ls("/");
    } else {
        // Parse arguments, skip options (starting with '-'), list directories
        let mut has_paths = false;
        for path in argv[1..].iter() {
            if is_option(path) {
                // Skip options like -a, -l, -al, etc.
                continue;
            }
            has_paths = true;
            ls(path);
        }

        // If no valid paths found, list current directory
        if !has_paths {
            ls("/");
        }
    }
    syscall_exit(0);
}
