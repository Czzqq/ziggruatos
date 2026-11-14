use crate::println;

#[repr(usize)]
pub enum SyscallNum {
    Fork = 1,
    Exit = 2,
    Wait = 3,
    Pipe = 4,
    Read = 5,
    Kill = 6,
    Exec = 7,
    Fstat = 8,
    Chdir = 9,
    Dup = 10,
    Getpid = 11,
    Sbrk = 12,
    Sleep = 13,
    Uptime = 14,
    Open = 15,
    Write = 16,
    Mknod = 17,
    Unlink = 18,
    Link = 19,
    Mkdir = 20,
    Close = 21,
    Console = 22,
    Readdir = 23,
    Getcwd = 24,
    Getcpu = 25,
}

const MAX_PATH: usize = 64;

/// Kernel result for a syscall number with no dispatch handler (ENOSYS).
pub const SYSCALL_NOT_IMPLEMENTED: isize = -38;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyscallError {
    NotImplemented,
    Failed(isize),
}

fn decode_result(ret: isize) -> Result<isize, SyscallError> {
    match ret {
        SYSCALL_NOT_IMPLEMENTED => Err(SyscallError::NotImplemented),
        value if value < 0 => Err(SyscallError::Failed(value)),
        value => Ok(value),
    }
}

#[inline(always)]
unsafe fn syscall(id: usize, arg0: usize, arg1: usize, arg2: usize) -> isize {
    let ret: isize;

    unsafe {
        core::arch::asm!(
            "ecall",
            in("a7") id, // x17
            inlateout("a0") arg0 => ret, // x10
            in("a1") arg1, // x11
            in("a2") arg2, // x12
            options(nostack)
        );
    }
    ret
}

// These numbers are part of the current ABI, but have no kernel handlers yet.
// Keep their wrappers callable so the test suite can check the kernel result.
pub fn syscall_pipe(fds: &mut [i32; 2]) -> Result<isize, SyscallError> {
    decode_result(unsafe { syscall(SyscallNum::Pipe as usize, fds.as_mut_ptr() as usize, 0, 0) })
}

pub fn syscall_fstat(fd: usize, stat: &mut [u8]) -> Result<isize, SyscallError> {
    decode_result(unsafe {
        syscall(
            SyscallNum::Fstat as usize,
            fd,
            stat.as_mut_ptr() as usize,
            0,
        )
    })
}

pub fn syscall_dup(fd: usize) -> Result<isize, SyscallError> {
    decode_result(unsafe { syscall(SyscallNum::Dup as usize, fd, 0, 0) })
}

pub fn syscall_sbrk(delta: isize) -> Result<isize, SyscallError> {
    decode_result(unsafe { syscall(SyscallNum::Sbrk as usize, delta as usize, 0, 0) })
}

pub fn syscall_uptime() -> Result<isize, SyscallError> {
    decode_result(unsafe { syscall(SyscallNum::Uptime as usize, 0, 0, 0) })
}

pub fn syscall_link(old: &str, new: &str) -> Result<isize, SyscallError> {
    if old.len() >= MAX_PATH || new.len() >= MAX_PATH {
        return Err(SyscallError::Failed(-1));
    }
    let mut old_buf = [0u8; MAX_PATH];
    let mut new_buf = [0u8; MAX_PATH];
    old_buf[..old.len()].copy_from_slice(old.as_bytes());
    new_buf[..new.len()].copy_from_slice(new.as_bytes());
    decode_result(unsafe {
        syscall(
            SyscallNum::Link as usize,
            old_buf.as_ptr() as usize,
            new_buf.as_ptr() as usize,
            0,
        )
    })
}

pub fn console_write(s: &str) {
    unsafe {
        syscall(
            SyscallNum::Console as usize,
            1,
            s.as_ptr() as usize,
            s.len(),
        );
    }
}

pub fn syscall_fork() -> isize {
    unsafe { syscall(SyscallNum::Fork as usize, 0, 0, 0) }
}
pub fn syscall_getpid() -> isize {
    unsafe { syscall(SyscallNum::Getpid as usize, 0, 0, 0) }
}

pub fn syscall_getcpu() -> isize {
    unsafe { syscall(SyscallNum::Getcpu as usize, 0, 0, 0) }
}

pub fn syscall_sleep(ticks: usize) -> isize {
    unsafe { syscall(SyscallNum::Sleep as usize, ticks, 0, 0) }
}

pub fn syscall_wait(addr: usize) -> isize {
    unsafe { syscall(SyscallNum::Wait as usize, addr, 0, 0) }
}

pub fn syscall_mknod(path: &str, mode: u32, dev: usize) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    unsafe {
        syscall(
            SyscallNum::Mknod as usize,
            buf.as_ptr() as usize,
            mode as usize,
            dev,
        )
    }
}

pub fn syscall_unlink(path: &str) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    unsafe { syscall(SyscallNum::Unlink as usize, buf.as_ptr() as usize, 0, 0) }
}

pub fn syscall_mkdir(path: &str, mode: u32) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    unsafe {
        syscall(
            SyscallNum::Mkdir as usize,
            buf.as_ptr() as usize,
            mode as usize,
            0,
        )
    }
}

pub fn syscall_open(path: &str, flags: u32) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    unsafe {
        syscall(
            SyscallNum::Open as usize,
            buf.as_ptr() as usize,
            flags as usize,
            0,
        )
    }
}

pub fn syscall_read(fd: usize, buf: &mut [u8]) -> isize {
    unsafe {
        syscall(
            SyscallNum::Read as usize,
            fd,
            buf.as_mut_ptr() as usize,
            buf.len() as usize,
        )
    }
}

pub fn syscall_write(fd: usize, buf: &[u8]) -> isize {
    unsafe {
        syscall(
            SyscallNum::Write as usize,
            fd,
            buf.as_ptr() as usize,
            buf.len(),
        )
    }
}

pub fn syscall_close(fd: usize) -> isize {
    unsafe { syscall(SyscallNum::Close as usize, fd, 0, 0) }
}

pub fn syscall_kill(pid: usize) -> isize {
    unsafe { syscall(SyscallNum::Kill as usize, pid, 0, 0) }
}

pub fn syscall_exec(path: &str, argv: &[*const u8]) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    /*
    use crate::println;
    println!("path: {}, len: {}\n", path, path_bytes.len());
    println!("argc: {}", argv.len());
    for (i, &arg_ptr) in argv.iter().enumerate() {
        if arg_ptr.is_null() {
            println!("argv[{}]: (null)", i);
            continue;
        }

        unsafe {
            let mut len = 0;
            while *arg_ptr.add(len) != 0 {
                len += 1;
            }

            let slice = core::slice::from_raw_parts(arg_ptr, len);

            match core::str::from_utf8(slice) {
                Ok(s) => println!("argv[{}]: {}", i, s),
                Err(_) => println!("argv[{}]: <invalid utf8>", i),
            }
        }
    }
    */

    unsafe {
        syscall(
            SyscallNum::Exec as usize,
            buf.as_ptr() as usize,
            argv.as_ptr() as usize,
            0,
        )
    }
}

pub fn syscall_exit(code: i32) -> ! {
    unsafe {
        syscall(SyscallNum::Exit as usize, code as usize, 0, 0);
    }
    loop {}
}

pub fn syscall_readdir(path: &str, buf: &mut [u8]) -> isize {
    println!("entry syscall readdir, path: {}\n", path);
    let mut path_buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= path_buf.len() {
        return -1; // path length limit
    }

    path_buf[..path_bytes.len()].copy_from_slice(path_bytes);
    println!("path str: {}\n", path);

    unsafe {
        syscall(
            SyscallNum::Readdir as usize,
            path_buf.as_ptr() as usize,
            buf.as_mut_ptr() as usize,
            buf.len(),
        )
    }
}

pub fn syscall_chdir(path: &str) -> isize {
    let mut buf: [u8; MAX_PATH] = [0u8; MAX_PATH];
    let path_bytes = path.as_bytes();

    if path_bytes.len() >= buf.len() {
        return -1; // path length limit
    }

    buf[..path_bytes.len()].copy_from_slice(path_bytes);

    unsafe { syscall(SyscallNum::Chdir as usize, buf.as_ptr() as usize, 0, 0) }
}

pub fn syscall_getcwd(buf: &mut [u8]) -> isize {
    unsafe {
        syscall(
            SyscallNum::Getcwd as usize,
            buf.as_mut_ptr() as usize,
            buf.len(),
            0,
        )
    }
}
