use crate::{syscall_close, syscall_open, syscall_read, syscall_unlink, syscall_write};
use core::fmt;

pub mod flags {
    pub const O_RDONLY: u32 = 0x0;
    pub const O_WRONLY: u32 = 0x1;
    pub const O_RDWR: u32 = 0x2;
    pub const O_ACCMODE: u32 = 0x3;
    pub const O_CREATE: u32 = 0x40;
    pub const O_TRUNC: u32 = 0x200;
}

pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

pub struct File {
    fd: isize,
}

impl File {
    pub fn open(path: &str, flags: u32) -> Result<File, &'static str> {
        let fd = syscall_open(path, flags);
        if fd < 0 {
            Err("failed to open file")
        } else {
            Ok(File { fd })
        }
    }

    // if has existed, truncate and open for write
    pub fn create(path: &str) -> Result<File, &'static str> {
        File::open(path, flags::O_CREATE | flags::O_WRONLY | flags::O_TRUNC)
    }

    pub fn from_fd(fd: isize) -> Self {
        File { fd }
    }

    pub fn fd(&self) -> isize {
        self.fd
    }

    pub fn read(&self, buf: &mut [u8]) -> Result<usize, &'static str> {
        let ret = syscall_read(self.fd as usize, buf);
        if ret < 0 {
            Err("failed to read from file")
        } else {
            Ok(ret as usize)
        }
    }

    pub fn write(&self, buf: &[u8]) -> Result<usize, &'static str> {
        let ret = syscall_write(self.fd as usize, buf);
        if ret < 0 {
            Err("failed to write to file")
        } else {
            Ok(ret as usize)
        }
    }

    pub fn write_str(&self, s: &str) -> Result<usize, &'static str> {
        self.write(s.as_bytes())
    }

    pub fn close(self) -> Result<(), &'static str> {
        let ret = syscall_close(self.fd as usize);
        core::mem::forget(self); // avoid double close
        if ret < 0 {
            Err("failed to close file")
        } else {
            Ok(())
        }
    }

    pub fn remove(path: &str) -> Result<(), &'static str> {
        let ret = syscall_unlink(path);
        if ret < 0 {
            Err("failed to open file")
        } else {
            Ok(())
        }
    }
}

impl Drop for File {
    fn drop(&mut self) {
        syscall_close(self.fd as usize);
    }
}

// implement fmt::Write for File, so we can use "write!" macro
impl fmt::Write for File {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        self.write(s.as_bytes()).map(|_| ()).map_err(|_| fmt::Error)
    }
}

// standard output
pub struct Stdout;
impl Stdout {
    pub fn write(&self, buf: &[u8]) -> Result<usize, &'static str> {
        let ret = syscall_write(STDOUT as usize, buf);
        if ret < 0 {
            Err("failed to write to stdout")
        } else {
            Ok(ret as usize)
        }
    }

    pub fn write_str(&self, s: &str) -> Result<usize, &'static str> {
        self.write(s.as_bytes())
    }
}

impl fmt::Write for Stdout {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        self.write(s.as_bytes()).map(|_| ()).map_err(|_| fmt::Error)
    }
}

// standard intput
pub struct Stdin;
impl Stdin {
    pub fn read(&self, buf: &mut [u8]) -> Result<usize, &'static str> {
        let ret = syscall_read(STDIN as usize, buf);
        if ret < 0 {
            Err("failed to read from stdin")
        } else {
            Ok(ret as usize)
        }
    }

    // read one line into the buffer until '\n' or buffer full
    pub fn read_line(&self, buf: &mut [u8]) -> Result<usize, &'static str> {
        let mut pos = 0;
        while pos < buf.len() {
            let mut byte = [0u8; 1];
            let n = self.read(&mut byte)?;
            if n == 0 {
                break; // EOF
            }
            buf[pos] = byte[0];
            pos += 1;
            if byte[0] == b'\n' {
                break; // end of line
            }
        }
        Ok(pos)
    }
}

pub fn stdout() -> Stdout {
    Stdout {}
}

pub fn stdin() -> Stdin {
    Stdin {}
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = write!($crate::file::stdout(), $($arg)*);
    }};
}

#[macro_export]
macro_rules! println {
    () => { $crate::print!("\n") };
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = writeln!($crate::file::stdout(), $($arg)*);
    }};
}
