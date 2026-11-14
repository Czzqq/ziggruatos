#![no_std]
#![no_main]

extern crate alloc;

use ziggurat_core::*;
use ziggurat_core::syscall::syscall_unlink;

fn unlink(path: &str) -> i32 {
    syscall_unlink(path) as i32
}

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc < 2 {
        println!("rm: missing operand");
        println!("Usage: rm <file>...");
        return 1;
    }

    for path in argv[1..].iter() {
        let code = unlink(path);
        if code != 0 {
            println!("rm: {} failed to delete", path);
        }
    }

    0
}
