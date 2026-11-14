#![no_std]
#![feature(linkage)]
#![feature(alloc_error_handler)]

extern crate alloc;

#[macro_use]
pub mod syscall;
pub mod console;
pub mod file;

pub use console::*;
pub use file::*;
pub use syscall::*;

use buddy_system_allocator::LockedHeap;
use core::panic::PanicInfo;

use core::ptr::addr_of_mut;

// File types matching kernel's FileType enum
#[repr(u32)]
#[derive(Debug)]
pub enum FileType {
    Regular = 0,
    Directory = 1,
    Device = 2,
    Symlink = 3,
    Unknown = 4,
}

use alloc::vec::Vec;

const USER_HEAP_SIZE: usize = 32768;

static mut HEAP_SPACE: [u8; USER_HEAP_SIZE] = [0; USER_HEAP_SIZE];

#[global_allocator]
static HEAP: LockedHeap = LockedHeap::empty();

#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.entry")]
pub extern "C" fn _start(argc: usize, argv: usize) -> ! {
    unsafe {
        HEAP.lock()
            .init(addr_of_mut!(HEAP_SPACE) as usize, USER_HEAP_SIZE);
    }
    let mut v: Vec<&'static str> = Vec::new();
    for i in 0..argc {
        let str_start =
            unsafe { ((argv + i * core::mem::size_of::<usize>()) as *const usize).read_volatile() };
        let len = (0usize..)
            .find(|i| unsafe { ((str_start + *i) as *const u8).read_volatile() == 0 })
            .unwrap();
        v.push(
            core::str::from_utf8(unsafe {
                core::slice::from_raw_parts(str_start as *const u8, len)
            })
            .unwrap(),
        );
    }
    syscall_exit(main(argc, v.as_slice()));
}

#[linkage = "weak"]
#[unsafe(no_mangle)]
fn main(_argc: usize, _argv: &[&str]) -> i32 {
    panic!("Cannot find main!");
}

#[alloc_error_handler]
pub fn handle_alloc_error(layout: core::alloc::Layout) -> ! {
    panic!("Heap allocation error, layout = {:?}", layout);
}

#[panic_handler]
pub fn panic(_info: &PanicInfo) -> ! {
    let err = _info.message();
    if let Some(location) = _info.location() {
        println!(
            "Panicked at {}:{}, {}",
            location.file(),
            location.line(),
            err
        );
    } else {
        println!("Panicked: {}", err);
    }
    syscall_kill(syscall_getpid() as usize);
    unreachable!()
}
