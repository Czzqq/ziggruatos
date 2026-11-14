#!/usr/bin/env python3
"""Build and run the guest syscall regression suite on a disposable QEMU disk."""

import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUMMARY = re.compile(rb"SYSCHECK SUMMARY pass=(\d+) fail=(\d+) skip=(\d+)")


def run() -> int:
    subprocess.run(["make"], cwd=ROOT, check=True)
    subprocess.run(["make", "-C", "tools/mkfs.zfs"], cwd=ROOT, check=True)

    with tempfile.TemporaryDirectory(prefix="ziggurat-syscheck-") as temp:
        disk = Path(temp) / "disk.img"
        subprocess.run([str(ROOT / "tools/mkfs.zfs/mkfs.zfs"), str(disk), "10"], check=True)

        command = [
            "qemu-system-riscv64", "-nographic", "-machine", "virt", "-m", "128M",
            "-bios", "sbi-fireware/fw_payload.bin",
            "-device", "loader,file=zig-out/initramfs/initramfs.cpio,addr=0x82300000",
            "-device", "loader,file=zig-out/bin/zigguratOS.bin,addr=0x80200000",
            "-device", "virtio-blk-device,drive=disk",
            "-drive", f"id=disk,file={disk},format=raw,if=none",
            "-smp", "cpus=2", "-kernel", "zig-out/bin/zigguratOS.bin",
        ]
        master, slave = pty.openpty()
        try:
            guest = subprocess.Popen(command, cwd=ROOT, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            slave = -1
            output = bytearray()
            sent = False
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.25)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > 200_000:
                        del output[:-100_000]
                    if not sent and b"ZigguratOS Shell" in output and b"/$ " in output:
                        os.write(master, b"syscheck\n")
                        sent = True
                    if sent:
                        match = SUMMARY.search(output)
                        if match:
                            for line in output.replace(b"\r", b"").splitlines():
                                if b"SYSCHECK " in line:
                                    print(line[line.index(b"SYSCHECK "):].decode("utf-8", errors="replace"))
                            passed, failed, _skipped = map(int, match.groups())
                            return 0 if passed > 0 and failed == 0 else 1
                if guest.poll() is not None:
                    break
            print("syscheck did not finish before QEMU exited or timed out", file=sys.stderr)
            print(output[-6000:].decode("utf-8", errors="replace"), file=sys.stderr)
            return 1
        finally:
            if slave >= 0:
                os.close(slave)
            guest.terminate()
            try:
                guest.wait(timeout=5)
            except subprocess.TimeoutExpired:
                guest.kill()
                guest.wait()
            os.close(master)


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"syscheck runner failed: {error}", file=sys.stderr)
        raise SystemExit(1)
