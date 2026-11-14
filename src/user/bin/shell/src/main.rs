#![no_std]
#![no_main]

extern crate alloc;

use ziggurat_core::file::stdin;
use ziggurat_core::*;

use alloc::string::String;
use alloc::vec::Vec;

const LF: u8 = 0x0au8;
const CR: u8 = 0x0du8;
const DL: u8 = 0x7fu8;
const BS: u8 = 0x08u8;

fn print_prompt() {
    let mut buf: [u8; 128] = [0; 128];
    let ret = syscall_getcwd(&mut buf);
    if ret >= 0 {
        let len = buf.iter().position(|&x| x == 0).unwrap_or(buf.len());
        let path = core::str::from_utf8(&buf[..len]).unwrap_or("/");
        print!("{}$ ", path);
    } else {
        print!("$ ");
    }
}

#[derive(Debug)]
struct ProcessArguments {
    input: String,
    output: String,
    args_copy: Vec<String>,
    args_addr: Vec<*const u8>,
}

impl ProcessArguments {
    pub fn new(command: &str) -> Self {
        // make a string vector from command line
        let args: Vec<_> = command.split(' ').collect();
        let mut args_copy: Vec<String> = args
            .iter()
            .filter(|&arg| !arg.is_empty())
            .map(|&arg| {
                let mut string = String::new();
                string.push_str(arg);
                string.push('\0');
                string
            })
            .collect();

        let mut input = String::new();
        if let Some((idx, _)) = args_copy
            .iter()
            .enumerate()
            .find(|(_, arg)| arg.as_str() == "<\0")
        {
            input = args_copy[idx + 1].clone();
            args_copy.drain(idx..=idx + 1);
        }

        let mut output = String::new();
        if let Some((idx, _)) = args_copy
            .iter()
            .enumerate()
            .find(|(_, arg)| arg.as_str() == ">\0")
        {
            output = args_copy[idx + 1].clone();
            args_copy.drain(idx..=idx + 1);
        }

        let mut args_addr: Vec<*const u8> = args_copy.iter().map(|arg| arg.as_ptr()).collect();
        args_addr.push(core::ptr::null::<u8>());

        Self {
            input,
            output,
            args_copy,
            args_addr,
        }
    }
}

#[unsafe(no_mangle)]
fn main() -> i32 {
    println!("ZigguratOS Shell");
    let mut line: String = String::new();

    print_prompt();

    loop {
        let mut buffer = [0u8; 1];
        // Print shell prompt

        // Read a line from stdin
        match stdin().read(&mut buffer) {
            Ok(len) if len > 0 => {
                let char = buffer[0];

                // Trim newline
                match char {
                    LF | CR => {
                        if !line.is_empty() {
                            // Convert to string
                            let cmd_str = line.as_str();

                            // TODO: pipe will have '|' to splited
                            let process_argument = ProcessArguments::new(cmd_str);

                            // Handle built-in commands
                            if process_argument.args_copy.is_empty() {
                                // Empty command, do nothing
                            } else if process_argument.args_copy[0].starts_with("cd\0") {
                                // Built-in cd command - run in parent process
                                if process_argument.args_copy.len() < 2 {
                                    println!("cd: missing operand");
                                } else {
                                    // Remove null terminator from path
                                    let path = &process_argument.args_copy[1];
                                    let path_str = &path[..path.len() - 1]; // Remove \0
                                    let ret = syscall_chdir(path_str);
                                    if ret < 0 {
                                        println!("cd: cannot change to {}", path_str);
                                    }
                                }
                            } else if process_argument.args_copy[0].starts_with("pwd\0") {
                                // Built-in pwd command
                                let mut buf: [u8; 128] = [0; 128];
                                let ret = syscall_getcwd(&mut buf);
                                if ret >= 0 {
                                    let len = buf.iter().position(|&x| x == 0).unwrap_or(buf.len());
                                    let path =
                                        core::str::from_utf8(&buf[..len]).unwrap_or("<invalid>");
                                    println!("{}", path);
                                } else {
                                    println!("pwd: failed to get current directory");
                                }
                            } else {
                                // Fork and execute the command
                                let pid = syscall_fork();
                                if pid < 0 {
                                    println!("fork failed");
                                    continue;
                                }

                                if pid == 0 {
                                    // Child process - execute the command
                                    // Simple implementation for now - just execute the path
                                    // without arguments
                                    syscall_exec(
                                        process_argument.args_copy[0].as_str(),
                                        process_argument.args_addr.as_slice(),
                                    );

                                    // If exec returns, it failed
                                    return 0;
                                } else {
                                    // Parent process - wait for child
                                    let mut exit_status: i32 = 0;
                                    syscall_wait(&mut exit_status as *mut i32 as usize);
                                }
                            }
                            line.clear();
                        }
                        print_prompt();
                    }
                    DL | BS => {
                        if !line.is_empty() {
                            print!("{}", BS as char);
                            print!(" ");
                            print!("{}", BS as char);
                            line.pop();
                        }
                    }
                    _ => {
                        line.push(char as char);
                    }
                }
            }
            Err(_) => {
                println!("read error");
                break;
            }
            _ => {
                break; // EOF
            }
        }
    }

    println!("Exit shell");
    return 0;
}
