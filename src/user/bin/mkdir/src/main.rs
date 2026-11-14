#![no_std]
#![no_main]

use ziggurat_core::syscall::syscall_mkdir;
use ziggurat_core::*;

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc < 2 {
        println!("mkdir: missing operand");
        println!("Usage: mkdir <directory>");
        return 1;
    }

    for count in 1..argc {
        let path = argv[count];
        let result = syscall_mkdir(path, 0o755);

        if result < 0 {
            println!(
                "mkdir: cannot create directory '{}': error {}",
                path, result
            );
            return 1;
        }
    }

    0
}
