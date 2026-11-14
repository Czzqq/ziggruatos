import argparse
import hashlib
import json
import struct
from pathlib import Path


LOAD_ADDRESS = 0x9F000000
ALLOCATOR_START = 0x9F800000
MEMORY_SIZE = 16 * 1024 * 1024


def inspect_image(elf, binary):
    header = struct.Struct("<16sHHIQQQIHHHHHH")
    program_header = struct.Struct("<IIQQQQQQ")
    if len(elf) < header.size:
        raise ValueError("truncated ELF header")
    fields = header.unpack_from(elf)
    ident, kind, machine, version, entry, offset = fields[:6]
    if ident[:7] != b"\x7fELF\x02\x01\x01" or kind != 2 or machine != 243 or version != 1:
        raise ValueError("expected a little-endian RISC-V ELF64 executable")
    if entry != LOAD_ADDRESS:
        raise ValueError("ELF entry does not match BLCP_2ND reset address")
    stride, count = fields[9:11]
    if stride != program_header.size or offset + stride * count > len(elf):
        raise ValueError("invalid ELF program headers")
    segments = []
    for index in range(count):
        segment = program_header.unpack_from(elf, offset + index * stride)
        segment_type, flags, file_offset, virtual, physical, file_size, memory_size, alignment = segment
        if segment_type != 1 or memory_size == 0:
            continue
        if virtual != physical or file_size > memory_size or file_offset + file_size > len(elf):
            raise ValueError("nonlinear or malformed load segment")
        if physical < LOAD_ADDRESS or physical + memory_size > ALLOCATOR_START:
            raise ValueError("kernel/BSS/stacks exceed the 8 MiB image allocation")
        if alignment and (physical - file_offset) % alignment:
            raise ValueError("misaligned load segment")
        segments.append((physical, file_size, memory_size, flags))
        raw_offset = physical - LOAD_ADDRESS
        if binary[raw_offset:raw_offset + file_size] != elf[file_offset:file_offset + file_size]:
            raise ValueError("raw image does not match ELF load contents")
    if not segments or min(segment[0] for segment in segments) != LOAD_ADDRESS:
        raise ValueError("missing reset-address load segment")
    ordered = sorted(segments)
    for previous, current in zip(ordered, ordered[1:]):
        if previous[0] + previous[2] > current[0]:
            raise ValueError("overlapping ELF load segments")
    if not any(address == LOAD_ADDRESS and flags & 1 for address, _, _, flags in segments):
        raise ValueError("reset address is not executable")
    image_size = max(address + size - LOAD_ADDRESS for address, size, _, _ in segments if size)
    if len(binary) != image_size:
        raise ValueError("raw image extent does not match ELF")
    return {
        "schema_version": 1,
        "target": "sg2000-c906l",
        "format": "raw",
        "load_address": LOAD_ADDRESS,
        "entry_address": entry,
        "memory_size": MEMORY_SIZE,
        "sha256": hashlib.sha256(binary).hexdigest(),
        "image_size": image_size,
        "static_memory_size": max(address + size - LOAD_ADDRESS for address, _, size, _ in segments),
        "allocator_address": ALLOCATOR_START,
        "allocator_size": LOAD_ADDRESS + MEMORY_SIZE - ALLOCATOR_START,
        "uart": "uart1",
        "uart_index": 1,
        "uart_address": 0x04150000,
        "privilege": "M-mode native kernel",
        "mmu_enabled": False,
        "application_abi": "linked trusted kernel tasks; legacy MMU ELFs unsupported",
    }


def main():
    parser = argparse.ArgumentParser(description="Validate small-core ELF/raw layout and write SDK metadata")
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = inspect_image(args.elf.read_bytes(), args.binary.read_bytes())
    except ValueError as error:
        parser.error(str(error))
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
