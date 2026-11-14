#![no_std]
#![no_main]

use core::fmt::{self, Write};
use ziggurat_core::{syscall_fork, syscall_getcpu, syscall_getpid, syscall_wait, syscall_write};

const ROUNDS: usize = 8;
const WORK_PER_ROUND: usize = 250_000;

// Build a complete line before writing it, so workers' output stays readable.
struct Line {
    bytes: [u8; 128],
    len: usize,
}

impl Line {
    fn new() -> Self {
        Self { bytes: [0; 128], len: 0 }
    }

    fn flush(&self) {
        let _ = syscall_write(1, &self.bytes[..self.len]);
    }
}

impl Write for Line {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let end = self.len + s.len();
        if end > self.bytes.len() {
            return Err(fmt::Error);
        }
        self.bytes[self.len..end].copy_from_slice(s.as_bytes());
        self.len = end;
        Ok(())
    }
}

fn worker(name: char) -> i32 {
    let pid = syscall_getpid();
    let mut seen_harts = 0usize;
    for round in 1..=ROUNDS {
        let mut checksum = 0usize;
        for n in 0..WORK_PER_ROUND {
            checksum = core::hint::black_box(checksum.wrapping_add(n ^ (pid as usize)));
        }

        // The hart is sampled by the kernel during this syscall. A process may
        // move between harts, so report the current hart on every round.
        let hart = syscall_getcpu();
        if hart >= 0 && (hart as u32) < usize::BITS {
            seen_harts |= 1usize << hart;
        }
        let mut line = Line::new();
        let _ = writeln!(line, "worker {name} pid={pid} hart={hart} round={round}/{ROUNDS} sum={checksum}");
        line.flush();
    }
    seen_harts as i32
}

#[unsafe(no_mangle)]
fn main() -> i32 {
    ziggurat_core::console_write("smpdemo: starting two CPU-bound workers\n");

    for name in ['A', 'B'] {
        let pid = syscall_fork();
        if pid < 0 {
            let mut error = Line::new();
            let _ = writeln!(error, "smpdemo: fork failed");
            error.flush();
            return 1;
        }
        if pid == 0 {
            return worker(name);
        }
    }

    let mut seen_harts = 0usize;
    for _ in 0..2 {
        let mut status = 0i32;
        if syscall_wait(&mut status as *mut i32 as usize) < 0 {
            return 1;
        }
        seen_harts |= status as usize;
    }
    let mut result = Line::new();
    let _ = writeln!(result, "smpdemo: observed hart mask=0b{seen_harts:b}");
    result.flush();
    if seen_harts & 0b11 == 0b11 { 0 } else { 1 }
}
