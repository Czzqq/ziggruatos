#![no_std]
#![no_main]

use core::str;
use ziggurat_core::*;

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    for count in 1..argc {
        print!("{}", argv[count]);
        if count + 1 < argc {
            print!(" ");
        } else {
            print!("\n");
        }
    }

    return 0;
}
