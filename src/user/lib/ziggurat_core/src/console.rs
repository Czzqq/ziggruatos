#![allow(dead_code)]

use crate::file::{STDERR, STDIN, STDOUT};
use crate::{flags, syscall_mknod, syscall_open};

pub mod dev {
    pub const CONSOLE: usize = 0x0001_0000; // Major=1 (character device), Minor=0
}

pub mod mode {
    pub const IFCHR: u32 = 0x100000; // character device
    pub const IFBLK: u32 = 0x060000; // block device
    pub const IFREG: usize = 0x8000; // regular file
}

pub fn init_stdio() -> Result<(), &'static str> {
    let ret = syscall_mknod("/dev/console", mode::IFCHR as u32, dev::CONSOLE);
    if ret < 0 {
        return Err("failed to create /dev/console");
    }

    // open stdin (fd 0)
    let fd = syscall_open("/dev/console", flags::O_RDONLY); // O_RDONLY
    if fd < 0 {
        return Err("failed to open console for stdin");
    }
    if fd != STDIN.try_into().unwrap() {
        return Err("stdin fd mismatch");
    }

    // open stdout (fd 1)
    let fd = syscall_open("/dev/console", flags::O_WRONLY); // O_WRONLY
    if fd < 0 {
        return Err("failed to open console for stdout");
    }
    if fd != STDOUT.try_into().unwrap() {
        return Err("stdout fd mismatch");
    }

    // open stderr (fd 2)
    let fd = syscall_open("/dev/console", flags::O_WRONLY); // O_WRONLY
    if fd < 0 {
        return Err("failed to open console for stderr");
    }
    if fd != STDERR.try_into().unwrap() {
        return Err("stderr fd mismatch");
    }

    Ok(())
}
