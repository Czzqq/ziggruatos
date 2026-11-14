#![no_std]
#![no_main]

use ziggurat_core::*;

fn touch(path: &str) -> i32 {
    let fd = syscall_open(path, flags::O_CREATE) as usize;

    syscall_close(fd) as i32
}

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc < 2 {
        println!("Usage: touch <file>...");
        return 1;
    }

    for path in argv[1..].iter() {
        let code = touch(path);
        if code != 0 {
            println!("touch: failed to touch {}", path);
        }
    }

    0
}
