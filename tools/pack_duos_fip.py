#!/usr/bin/env python3
"""Package a ZigguratOS raw image as the Milk-V DuoS LOADER_2ND."""

import argparse
import hashlib
import lzma
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


KERNEL_ENTRY = 0x8020_0000
LOADER_HEADER_SIZE = struct.calcsize("<IIIIQII")
LOADER_HEADER = struct.Struct("<IIIIQII")
LOADER_SIZE_OFFSET = 12
LOADER_MAGIC_RAW = int.from_bytes(b"BL33", "little")
LOADER_MAGIC_LZMA = b"B3MA"
FSBL_DECOMPRESS_LIMIT = 16 * 1024 * 1024
EMMC_LBA_SIZE = 512
EMMC_FIP_SLOT_SIZE = 0x800 * EMMC_LBA_SIZE
EMMC_BOOT_IMAGE_SIZE = EMMC_FIP_SLOT_SIZE * 2
EMMC_ERASED_BYTE = 0xFF

PARAM2_LOADADDR_OFFSET = 0xE0
MONITOR_RUNADDR_OFFSET = 0x3C
MONITOR_LOADADDR_OFFSET = 0x34
MONITOR_SIZE_OFFSET = 0x38
LOADER_LOADADDR_OFFSET = 0x44


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def parse_fip(data):
    if len(data) < PARAM2_LOADADDR_OFFSET + 4:
        raise ValueError("base FIP is too small")

    param2 = read_u32(data, PARAM2_LOADADDR_OFFSET)
    if param2 + 0x54 > len(data):
        raise ValueError("base FIP has an invalid FIP2 parameter table")

    monitor_load = read_u32(data, param2 + MONITOR_LOADADDR_OFFSET)
    monitor_size = read_u32(data, param2 + MONITOR_SIZE_OFFSET)
    monitor_run = read_u32(data, param2 + MONITOR_RUNADDR_OFFSET)
    loader_load = read_u32(data, param2 + LOADER_LOADADDR_OFFSET)

    if monitor_size == 0 or monitor_load + monitor_size > len(data):
        raise ValueError("base FIP does not contain a valid OpenSBI monitor")
    if loader_load == 0 or loader_load + LOADER_HEADER_SIZE > len(data):
        raise ValueError("base FIP does not contain a valid LOADER_2ND")

    monitor = data[monitor_load : monitor_load + monitor_size]
    if b"OpenSBI" not in monitor:
        raise ValueError("base FIP monitor does not look like OpenSBI")

    return {
        "param2": param2,
        "monitor_load": monitor_load,
        "monitor_size": monitor_size,
        "monitor_run": monitor_run,
        "monitor": monitor,
        "loader_load": loader_load,
    }


def make_loader(kernel):
    if not kernel:
        raise ValueError("kernel image is empty")
    if len(kernel) + LOADER_HEADER_SIZE > FSBL_DECOMPRESS_LIMIT:
        raise ValueError(
            "kernel image exceeds the DuoS FSBL 16 MiB decompression limit"
        )

    # FSBL jumps to runaddr + sizeof(loader_2nd_header). Place the header
    # immediately before the kernel so the kernel's linked entry is retained.
    runaddr = KERNEL_ENTRY - LOADER_HEADER_SIZE
    header = LOADER_HEADER.pack(
        0,
        LOADER_MAGIC_RAW,
        0,
        LOADER_HEADER_SIZE + len(kernel),
        runaddr,
        0,
        0,
    )
    return header + kernel, runaddr


def run_fiptool(sdk, base_fip, loader, output):
    fiptool = sdk / "fsbl" / "plat" / "cv181x" / "fiptool.py"
    if not fiptool.is_file():
        raise FileNotFoundError(f"SDK fiptool not found: {fiptool}")

    command = [
        sys.executable,
        str(fiptool),
        "-v",
        "genfip",
        str(output),
        "--OLD_FIP",
        str(base_fip),
        "--LOADER_2ND",
        str(loader),
        "--compress=lzma",
    ]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError("SDK fiptool failed")


def verify_loader_payload(fip_data, packaged, expected):
    loader_offset = packaged["loader_load"]
    if loader_offset + LOADER_HEADER_SIZE > len(fip_data):
        raise ValueError("packaged LOADER_2ND header is truncated")

    loader_size = read_u32(fip_data, loader_offset + LOADER_SIZE_OFFSET)
    if (
        loader_size < LOADER_HEADER_SIZE
        or loader_offset + loader_size > len(fip_data)
    ):
        raise ValueError("packaged LOADER_2ND has an invalid size")

    compressed = fip_data[
        loader_offset + LOADER_HEADER_SIZE : loader_offset + loader_size
    ]
    decompressor = lzma.LZMADecompressor()
    try:
        payload = decompressor.decompress(compressed)
    except lzma.LZMAError as error:
        raise ValueError(f"packaged LOADER_2ND cannot be decompressed: {error}")

    if not decompressor.eof:
        raise ValueError("packaged LOADER_2ND has a truncated LZMA stream")
    if payload != expected:
        raise ValueError("packaged LOADER_2ND does not match the kernel image")
    return loader_size


def make_emmc_boot_images(fip_data):
    if len(fip_data) > EMMC_FIP_SLOT_SIZE:
        raise ValueError(
            f"FIP is {len(fip_data)} bytes, exceeding the "
            f"{EMMC_FIP_SLOT_SIZE}-byte eMMC boot slot"
        )

    padding = bytes([EMMC_ERASED_BYTE]) * (EMMC_FIP_SLOT_SIZE - len(fip_data))
    primary = fip_data + padding
    boot_image = primary + primary

    if len(primary) != EMMC_FIP_SLOT_SIZE:
        raise RuntimeError("internal error: primary FIP slot has the wrong size")
    if len(boot_image) != EMMC_BOOT_IMAGE_SIZE:
        raise RuntimeError("internal error: eMMC boot image has the wrong size")
    if boot_image[: len(fip_data)] != fip_data:
        raise RuntimeError("internal error: eMMC boot image lost the FIP prefix")
    if boot_image[EMMC_FIP_SLOT_SIZE:] != primary:
        raise RuntimeError("internal error: eMMC FIP backup slot differs")

    return primary, boot_image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--base-fip", required=True, type=Path)
    parser.add_argument(
        "--kernel", type=Path, default=Path("zig-out/bin/zigguratOS.bin")
    )
    parser.add_argument("--output-dir", type=Path, default=Path("zig-out/duos"))
    args = parser.parse_args()

    if LOADER_HEADER_SIZE != 32:
        raise RuntimeError("unexpected DuoS loader header layout")

    base_data = args.base_fip.read_bytes()
    base = parse_fip(base_data)
    kernel = args.kernel.read_bytes()
    loader, runaddr = make_loader(kernel)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    loader_path = args.output_dir / "loader-2nd.bin"
    output_fip = args.output_dir / "fip.bin"
    loader_path.write_bytes(loader)

    with tempfile.TemporaryDirectory(prefix="ziggurat-duos-") as temp:
        temp_fip = Path(temp) / "fip.bin"
        run_fiptool(args.sdk, args.base_fip, loader_path, temp_fip)
        output_data = temp_fip.read_bytes()

    packaged = parse_fip(output_data)
    if packaged["monitor"] != base["monitor"]:
        raise RuntimeError("packaged FIP changed the SDK OpenSBI monitor")
    if packaged["monitor_run"] != base["monitor_run"]:
        raise RuntimeError("packaged FIP changed the OpenSBI monitor run address")

    loader_offset = packaged["loader_load"]
    magic = output_data[loader_offset + 4 : loader_offset + 8]
    packaged_runaddr = struct.unpack_from(
        "<Q", output_data, loader_offset + 16
    )[0]
    if magic != LOADER_MAGIC_LZMA:
        raise RuntimeError(f"packaged LOADER_2ND has unexpected magic: {magic!r}")
    if packaged_runaddr != runaddr:
        raise RuntimeError(
            f"packaged LOADER_2ND run address is 0x{packaged_runaddr:x}, "
            f"expected 0x{runaddr:x}"
        )
    loader_size = verify_loader_payload(output_data, packaged, kernel)

    output_fip.write_bytes(output_data)
    digest = sha256(output_data)
    (args.output_dir / "fip.sha256").write_text(f"{digest}  fip.bin\n")

    primary_data, boot_data = make_emmc_boot_images(output_data)
    primary_path = args.output_dir / "fip-primary-1m.img"
    boot_path = args.output_dir / "Boot.bin"
    primary_path.write_bytes(primary_data)
    boot_path.write_bytes(boot_data)
    boot_digest = sha256(boot_data)
    (args.output_dir / "Boot.bin.sha256").write_text(
        f"{boot_digest}  Boot.bin\n"
    )

    print(f"kernel:       {args.kernel} ({len(kernel)} bytes)")
    print(
        f"loader entry: 0x{runaddr + LOADER_HEADER_SIZE:08x} "
        f"(header at 0x{runaddr:08x})"
    )
    print(
        f"OpenSBI:      run=0x{packaged['monitor_run']:08x}, "
        f"size={packaged['monitor_size']} bytes (preserved)"
    )
    print(
        f"LOADER_2ND:   offset=0x{loader_offset:x}, "
        f"size={loader_size} bytes (payload verified)"
    )
    print(f"FIP:          {output_fip} ({len(output_data)} bytes)")
    print(f"FIP sha256:   {digest}")
    print(f"boot slot:    {primary_path} ({len(primary_data)} bytes)")
    print(f"Boot image:   {boot_path} ({len(boot_data)} bytes)")
    print(f"Boot sha256:  {boot_digest}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
