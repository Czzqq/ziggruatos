#![no_std]
#![no_main]

use ziggurat_core::*;

#[unsafe(no_mangle)]
fn main() -> i32 {
    console::init_stdio().expect("failed to init stdio");

    loop {
        println!("ZigguratOS Init Process");
        let pid = syscall_fork();
        if pid < 0 {
            println!("fork failed");
            return 1;
        }
        if pid == 0 {
            // Child process - execute the shell
            let argv = ["/shell\0".as_ptr(), core::ptr::null::<u8>()];
            syscall_exec("/shell", &argv);

            // If we get here, exec failed
            println!("Failed to exec shell");
            return 1;
        }

        loop {
            let mut exit_status: i32 = 0;
            let ret = syscall_wait(&mut exit_status as *mut i32 as usize);
            if ret < 0 {
                println!("wait failed");
                return 0;
            }
            if ret == pid {
                println!("Shell exited with status {}", exit_status);
                break;
            }
        }
    }
}
