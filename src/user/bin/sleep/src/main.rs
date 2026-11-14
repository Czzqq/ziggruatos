#![no_std]
#![no_main]

use core::str;
use core::str::FromStr;
use ziggurat_core::*;

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc != 2 {
        println!("Usage: sleep <seconds>...");
        return 1;
    }

    let ticks = usize::from_str(argv[1]).unwrap();

    syscall_sleep(ticks);

    return 0;
}
