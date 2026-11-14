#![no_std]
#![no_main]

extern crate alloc;

use alloc::format;
use core::fmt::{self, Write};
use ziggurat_core::{
    SyscallError, flags, syscall_chdir, syscall_close, syscall_dup, syscall_exec, syscall_fork,
    syscall_fstat, syscall_getcpu, syscall_getcwd, syscall_getpid, syscall_link, syscall_mkdir,
    syscall_open, syscall_pipe, syscall_read, syscall_readdir, syscall_sbrk, syscall_sleep,
    syscall_unlink, syscall_uptime, syscall_wait, syscall_write,
};

const SELF_PATH: &str = "/syscheck";
const CHILD_ARG: &str = "--exec-child";
const CHILD_EXIT: i32 = 37;
const MAX_CPUS: isize = 2; // riscv/asm/constants.h
const INDIRECT_FILE_SIZE: usize = 64 * 1024;
const IO_CHUNK_SIZE: usize = 1024;

// Each record is one write, so concurrent kernel logs cannot split a result.
struct Line {
    bytes: [u8; 160],
    len: usize,
}

impl Line {
    fn new() -> Self {
        Self {
            bytes: [0; 160],
            len: 0,
        }
    }

    fn emit(&self) {
        let _ = syscall_write(1, &self.bytes[..self.len]);
    }
}

impl Write for Line {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        let end = self.len.checked_add(text.len()).ok_or(fmt::Error)?;
        if end > self.bytes.len() {
            return Err(fmt::Error);
        }
        self.bytes[self.len..end].copy_from_slice(text.as_bytes());
        self.len = end;
        Ok(())
    }
}

fn result(kind: &str, name: &str, detail: &str) {
    let mut line = Line::new();
    let _ = writeln!(line, "SYSCHECK {kind} {name}: {detail}");
    line.emit();
}

struct Summary {
    pass: usize,
    fail: usize,
    skip: usize,
}

impl Summary {
    fn check(&mut self, name: &str, test: fn() -> Result<(), &'static str>) {
        match test() {
            Ok(()) => {
                self.pass += 1;
                result("PASS", name, "ok");
            }
            Err(reason) => {
                self.fail += 1;
                result("FAIL", name, reason);
            }
        }
    }

    fn check_unsupported(&mut self, name: &str, actual: Result<isize, SyscallError>) {
        match actual {
            Err(SyscallError::NotImplemented) => {
                self.skip += 1;
                result("SKIP", name, "kernel returned NotImplemented");
            }
            Err(SyscallError::Failed(_)) => {
                self.fail += 1;
                result("FAIL", name, "returned a different error");
            }
            Ok(_) => {
                self.fail += 1;
                result("FAIL", name, "unexpectedly succeeded; add a behavior test");
            }
        }
    }

    fn finish(&self) -> i32 {
        let mut line = Line::new();
        let _ = writeln!(
            line,
            "SYSCHECK SUMMARY pass={} fail={} skip={}",
            self.pass, self.fail, self.skip
        );
        line.emit();
        if self.fail == 0 { 0 } else { 1 }
    }
}

fn test_identity() -> Result<(), &'static str> {
    if syscall_getpid() <= 0 {
        return Err("getpid did not return a positive PID");
    }
    let hart = syscall_getcpu();
    if !(0..MAX_CPUS).contains(&hart) {
        return Err("getcpu returned an invalid hart ID");
    }
    Ok(())
}

fn test_sleep() -> Result<(), &'static str> {
    // This tests completion, not wall-clock duration: jiffies is shared by harts.
    if syscall_sleep(1) != 0 {
        return Err("sleep(1) failed");
    }
    Ok(())
}

fn test_bad_fd() -> Result<(), &'static str> {
    let mut byte = [0u8; 1];
    if syscall_read(usize::MAX, &mut byte) != -1 {
        return Err("read with invalid fd did not fail");
    }
    if syscall_write(usize::MAX, b"x") != -1 {
        return Err("write with invalid fd did not fail");
    }
    if syscall_close(usize::MAX) != -1 {
        return Err("close with invalid fd did not fail");
    }
    Ok(())
}

fn test_missing_path() -> Result<(), &'static str> {
    // This name is reserved for the suite. No filesystem content is changed.
    if syscall_open("/syscheck-missing-file", flags::O_RDONLY) != -1 {
        return Err("open on a missing file did not fail");
    }
    if syscall_chdir("/syscheck-missing-directory") != -1 {
        return Err("chdir on a missing directory did not fail");
    }
    Ok(())
}

fn readdir_contains(path: &str, wanted: &str) -> Result<bool, &'static str> {
    let mut buf = [0u8; 2048];
    let len = syscall_readdir(path, &mut buf);
    if len < 4 {
        return Err("readdir returned no entry header");
    }
    let len = len as usize;
    let count = u32::from_le_bytes(buf[0..4].try_into().unwrap()) as usize;
    let mut pos = 4usize;
    for _ in 0..count {
        if pos.checked_add(16).ok_or("readdir offset overflow")? > len {
            return Err("truncated readdir entry");
        }
        let name_len = u32::from_le_bytes(buf[pos + 12..pos + 16].try_into().unwrap()) as usize;
        pos += 16;
        let end = pos.checked_add(name_len).ok_or("readdir name overflow")?;
        if end > len {
            return Err("truncated readdir name");
        }
        if &buf[pos..end] == wanted.as_bytes() {
            return Ok(true);
        }
        pos = (end + 7) & !7;
        if pos > len {
            return Err("truncated readdir padding");
        }
    }
    Ok(false)
}

fn test_filesystem() -> Result<(), &'static str> {
    let pid = syscall_getpid();
    if pid <= 0 {
        return Err("no PID for test directory");
    }
    // A reused PID after a crash must not overwrite a pre-existing file.
    let dir = format!("/syscheck-{pid}");
    let path = format!("{dir}/data");
    let existing = syscall_open(&dir, flags::O_RDONLY);
    if existing >= 0 {
        let _ = syscall_close(existing as usize);
        return Err("test path exists; refusing to overwrite it");
    }
    if syscall_mkdir(&dir, 0o755) != 0 {
        return Err("mkdir failed");
    }

    // Keep the test directory even when a check fails, then clean it below.
    let mut file_created = false;
    let checked = (|| -> Result<(), &'static str> {
        if syscall_mkdir(&dir, 0o755) != -1 {
            return Err("duplicate mkdir did not fail");
        }
        if syscall_chdir(&dir) != 0 {
            return Err("chdir into test directory failed");
        }
        let mut cwd = [0u8; 128];
        if syscall_getcwd(&mut cwd) < 0 {
            return Err("getcwd failed");
        }
        let end = cwd.iter().position(|&b| b == 0).unwrap_or(cwd.len());
        if &cwd[..end] != dir.as_bytes() {
            return Err("getcwd returned the wrong path");
        }
        if syscall_chdir("/") != 0 {
            return Err("chdir back to root failed");
        }

        let fd = syscall_open(&path, flags::O_CREATE | flags::O_RDWR);
        if fd < 0 {
            return Err("create/open failed");
        }
        file_created = true;
        let message = b"ZigguratOS syscall regression\n";
        let write_ok = syscall_write(fd as usize, message) == message.len() as isize;
        let close_ok = syscall_close(fd as usize) == 0;
        if !write_ok || !close_ok {
            return Err("write or close failed");
        }
        let fd = syscall_open(&path, flags::O_RDONLY);
        if fd < 0 {
            return Err("reopen failed");
        }
        let mut buf = [0u8; 64];
        let read_ok = syscall_read(fd as usize, &mut buf) == message.len() as isize
            && &buf[..message.len()] == message
            && syscall_read(fd as usize, &mut buf) == 0;
        let close_ok = syscall_close(fd as usize) == 0;
        if !read_ok || !close_ok {
            return Err("read, EOF, or close failed");
        }
        if !readdir_contains(&dir, "data")? {
            return Err("readdir omitted the created file");
        }
        Ok(())
    })();

    // No rmdir syscall exists; unlink currently handles empty directories.
    let _ = syscall_chdir("/");
    let file_removed = !file_created || syscall_unlink(&path) == 0;
    let dir_removed = syscall_unlink(&dir) == 0;
    if !file_removed || !dir_removed {
        return Err("test cleanup failed; inspect /syscheck-<pid>");
    }
    checked?;
    if syscall_open(&path, flags::O_RDONLY) != -1 {
        return Err("unlinked file is still accessible");
    }
    Ok(())
}

fn pattern_byte(offset: usize) -> u8 {
    ((offset * 37) % 251) as u8
}

fn fill_pattern(buffer: &mut [u8], offset: usize) {
    for (index, byte) in buffer.iter_mut().enumerate() {
        *byte = pattern_byte(offset + index);
    }
}

fn verify_pattern(buffer: &[u8], offset: usize) -> bool {
    buffer
        .iter()
        .enumerate()
        .all(|(index, byte)| *byte == pattern_byte(offset + index))
}

fn test_indirect_file() -> Result<(), &'static str> {
    let pid = syscall_getpid();
    if pid <= 0 {
        return Err("no PID for indirect-file test directory");
    }
    let dir = format!("/syscheck-indirect-{pid}");
    let path = format!("{dir}/data");
    let existing = syscall_open(&dir, flags::O_RDONLY);
    if existing >= 0 {
        let _ = syscall_close(existing as usize);
        return Err("test path exists; refusing to overwrite it");
    }
    if syscall_mkdir(&dir, 0o755) != 0 {
        return Err("mkdir failed");
    }

    let mut file_created = false;
    let checked = (|| -> Result<(), &'static str> {
        let fd = syscall_open(&path, flags::O_CREATE | flags::O_RDWR);
        if fd < 0 {
            return Err("create/open failed");
        }
        file_created = true;

        let mut buffer = [0u8; IO_CHUNK_SIZE];
        let mut offset = 0usize;
        while offset < INDIRECT_FILE_SIZE {
            fill_pattern(&mut buffer, offset);
            if syscall_write(fd as usize, &buffer) != IO_CHUNK_SIZE as isize {
                let _ = syscall_close(fd as usize);
                return Err("large chunk write failed");
            }
            offset += IO_CHUNK_SIZE;
        }
        if syscall_close(fd as usize) != 0 {
            return Err("close after large write failed");
        }

        let fd = syscall_open(&path, flags::O_RDONLY);
        if fd < 0 {
            return Err("reopen after large write failed");
        }
        offset = 0;
        while offset < INDIRECT_FILE_SIZE {
            let got = syscall_read(fd as usize, &mut buffer);
            if got != IO_CHUNK_SIZE as isize {
                let _ = syscall_close(fd as usize);
                return Err("short large-file read");
            }
            if !verify_pattern(&buffer, offset) {
                let _ = syscall_close(fd as usize);
                return Err("large-file payload mismatch");
            }
            offset += IO_CHUNK_SIZE;
        }
        if syscall_read(fd as usize, &mut buffer) != 0 {
            let _ = syscall_close(fd as usize);
            return Err("large file did not reach EOF");
        }
        if syscall_close(fd as usize) != 0 {
            return Err("close after large read failed");
        }
        Ok(())
    })();

    let file_removed = !file_created || syscall_unlink(&path) == 0;
    let dir_removed = syscall_unlink(&dir) == 0;
    if !file_removed || !dir_removed {
        return Err("indirect-file test cleanup failed");
    }
    checked
}

fn test_fork_wait() -> Result<(), &'static str> {
    let pid = syscall_fork();
    if pid < 0 {
        return Err("fork failed");
    }
    if pid == 0 {
        ziggurat_core::syscall_exit(23);
    }
    let mut status = -1i32;
    if syscall_wait(&mut status as *mut i32 as usize) != pid {
        return Err("wait returned a different PID");
    }
    if status != 23 {
        return Err("wait returned the wrong exit status");
    }
    Ok(())
}

fn test_exec() -> Result<(), &'static str> {
    let pid = syscall_fork();
    if pid < 0 {
        return Err("fork for exec failed");
    }
    if pid == 0 {
        let argv = [
            b"/syscheck\0".as_ptr(),
            b"--exec-child\0".as_ptr(),
            core::ptr::null(),
        ];
        let _ = syscall_exec(SELF_PATH, &argv);
        ziggurat_core::syscall_exit(99);
    }
    let mut status = -1i32;
    if syscall_wait(&mut status as *mut i32 as usize) != pid {
        return Err("wait after exec returned a different PID");
    }
    if status != CHILD_EXIT {
        return Err("exec child returned the wrong status (99 means exec failed)");
    }
    Ok(())
}

#[unsafe(no_mangle)]
fn main(argc: usize, argv: &[&str]) -> i32 {
    if argc == 2 && argv[1] == CHILD_ARG {
        return CHILD_EXIT;
    }

    let mut summary = Summary {
        pass: 0,
        fail: 0,
        skip: 0,
    };
    summary.check("identity/getcpu", test_identity);
    summary.check("sleep", test_sleep);
    summary.check("invalid-fd", test_bad_fd);
    summary.check("missing-path", test_missing_path);
    summary.check("filesystem", test_filesystem);
    summary.check("filesystem-indirect", test_indirect_file);
    summary.check("fork/wait", test_fork_wait);
    summary.check("exec", test_exec);

    // Actually invoke every numbered call without a handler. A plain -1 must
    // fail: only the dedicated NotImplemented result warrants a skip.
    let mut pipe_fds = [-1i32; 2];
    let pipe_result = syscall_pipe(&mut pipe_fds);
    if pipe_result.is_ok() {
        for fd in pipe_fds {
            if fd >= 0 {
                let _ = syscall_close(fd as usize);
            }
        }
    }
    summary.check_unsupported("pipe", pipe_result);
    let mut stat = [0u8; 128];
    summary.check_unsupported("fstat", syscall_fstat(usize::MAX, &mut stat));
    summary.check_unsupported("dup", syscall_dup(usize::MAX));
    summary.check_unsupported("sbrk", syscall_sbrk(0));
    summary.check_unsupported("uptime", syscall_uptime());
    summary.check_unsupported(
        "link",
        syscall_link("/syscheck-missing-file", "/syscheck-link-target"),
    );

    summary.finish()
}
