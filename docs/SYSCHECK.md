# Kernel syscall regression suite

`syscheck` is a Rust `no_std` guest binary in `src/user/bin/syscheck`. It follows the
small, independent checks in [xv6 usertests](https://github.com/mit-pdos/xv6-public/blob/master/usertests.c)
and the PASS/FAIL/SKIP distinction used by the [Linux Test Project](https://github.com/linux-test-project/ltp/blob/master/doc/users/quick_start.rst).
Its cases target ZigguratOS's own syscall numbers and return values, not Linux ABI behavior.

Run the complete check with:

```bash
python3 tools/run_syscheck.py
```

The runner builds the kernel and userspace, formats a **temporary** 10 MiB ZFS
image, starts two-hart QEMU, enters `syscheck` at the guest shell, and exits
nonzero on a failure or timeout. It does not use or modify the repository's
`disk.img`. It requires the tools listed in [README](../README.md), including
OpenSBI firmware, QEMU, Zig and Rust nightly.

You can also run `syscheck` directly in the guest shell after `make run`. Its
last line has the stable form:

```text
SYSCHECK SUMMARY pass=8 fail=0 skip=6
```

The suite checks `getpid`, `getcpu`, `sleep`, bad file descriptors, missing paths,
`mkdir`, `chdir`, `getcwd`, `open`, `write`, `close`, `read`, EOF, `readdir`,
`unlink`, `fork`, `wait`, and `exec`, including a file crossing the direct-block boundary. It checks results and cleanup, not just
whether a syscall returns. The filesystem case uses `/syscheck-<pid>`, refuses
to overwrite an existing path, and removes its file and empty directory on exit.
The indirect-block case uses `/syscheck-indirect-<pid>`. An interrupted run
may leave either test path; inspect and remove leftovers manually.

`pipe`, `fstat`, `dup`, `sbrk`, `uptime` and `link` have syscall numbers but no
kernel handlers. The suite **invokes every one** through its Rust wrapper and
reports SKIP only when the kernel returns the dedicated `-38` (ENOSYS) result,
translated to `SyscallError::NotImplemented`. A generic `-1`, another error, or
an unexpected success is a FAIL. Add a behavior case when each handler lands.
`kill` and `mknod` already have handlers but
are outside this basic non-disruptive set. The suite does not prove storage
concurrency safety or accurate wall-clock `sleep` duration.

The current suite has eight behavior cases and six expected unimplemented-call
checks. The summary above is the expected successful shape, not a result from
this documentation update. The exit code is 0 only if no case failed. This suite
does not replace physical-board validation or storage concurrency testing.
