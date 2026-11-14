#![no_std]
#![no_main]

use ziggurat_core::*;

fn cat(path: &str) -> i32 {
    // Open file
    let fd = syscall_open(path, 0);
    if fd < 0 {
        println!("cat: cannot open '{}'", path);
        return 1;
    }
    let fd = fd as usize;

    // Read and output file content
    let mut buf = [0u8; 512];
    loop {
        let n = syscall_read(fd, &mut buf);
        if n <= 0 {
            break;
        }
        let n = n as usize;

        // Write to stdout
        syscall_write(1, &buf[..n]);
    }

    syscall_close(fd);
    0
}

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc < 2 {
        println!("Usage: cat <file>...");
        return 1;
    }

    let mut exit_code = 0;
    for path in argv[1..].iter() {
        let code = cat(path);
        if code != 0 {
            exit_code = code;
        }
    }

    exit_code
}
