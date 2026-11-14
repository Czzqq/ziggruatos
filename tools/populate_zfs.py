#!/usr/bin/env python3
"""
populate_zfs - Copy user binaries to ZFS disk image
Similar to cpio but for ZFS filesystem

Usage: populate_zfs <disk_image> <source_dir> [target_path]
  disk_image: Path to ZFS disk image
  source_dir: Directory containing files to copy
  target_path: Target path in ZFS (default: /)

Example:
  populate_zfs disk.img out/user /
  populate_zfs disk.img out/user /persist
"""

import sys
import os
import struct
from pathlib import Path

# ZFS constants
BLOCK_SIZE = 4096
MAX_NAME_LEN = 24
DIRECT_BLOCKS = 12
PTRS_PER_BLOCK = BLOCK_SIZE // 4
SINGLE_INDIRECT_BLOCKS = PTRS_PER_BLOCK
MAX_LOGICAL_BLOCKS = DIRECT_BLOCKS + SINGLE_INDIRECT_BLOCKS
MAX_FILE_SIZE = MAX_LOGICAL_BLOCKS * BLOCK_SIZE
ZFS_MAGIC = 0x5A495353554D4F21
ZFS_VERSION = 2
ZFS_TYPE_FREE = 0
ZFS_TYPE_REGULAR = 1
ZFS_TYPE_DIRECTORY = 2

class ZFSImage:
    def __init__(self, image_path):
        self.image_path = image_path
        self.fd = None
        self.superblock = None
        self.open()

    def open(self):
        """Open and read superblock"""
        self.fd = open(self.image_path, 'r+b')

        # Read superblock (at block 1)
        self.fd.seek(BLOCK_SIZE)
        sb_data = self.fd.read(512)

        # Unpack superblock
        self.superblock = {
            'magic': struct.unpack('<Q', sb_data[0:8])[0],
            'version': struct.unpack('<I', sb_data[8:12])[0],
            'block_size': struct.unpack('<I', sb_data[12:16])[0],
            'block_count': struct.unpack('<I', sb_data[16:20])[0],
            'inode_count': struct.unpack('<I', sb_data[20:24])[0],
            'free_blocks': struct.unpack('<I', sb_data[24:28])[0],
            'free_inodes': struct.unpack('<I', sb_data[28:32])[0],
            'root_inode': struct.unpack('<I', sb_data[32:36])[0],
            'creation_time': struct.unpack('<Q', sb_data[40:48])[0],
            'block_bitmap_start': struct.unpack('<I', sb_data[48:52])[0],
            'inode_bitmap_start': struct.unpack('<I', sb_data[52:56])[0],
            'inode_table_start': struct.unpack('<I', sb_data[56:60])[0],
            'data_start': struct.unpack('<I', sb_data[60:64])[0],
        }

        if self.superblock['magic'] != ZFS_MAGIC:
            raise ValueError(f"Invalid ZFS magic: {hex(self.superblock['magic'])}")
        if self.superblock['version'] != ZFS_VERSION:
            raise ValueError(
                f"Unsupported ZFS version: {self.superblock['version']} "
                f"(expected {ZFS_VERSION})"
            )

        print(f"ZFS image: {self.superblock['block_count']} blocks, "
              f"{self.superblock['inode_count']} inodes")
        print(f"  Data starts at block {self.superblock['data_start']}")

    def write_superblock(self):
        """Write superblock fields back to disk."""
        sb_data = bytearray(512)
        sb = self.superblock
        sb_data[0:8] = struct.pack('<Q', sb['magic'])
        sb_data[8:12] = struct.pack('<I', sb['version'])
        sb_data[12:16] = struct.pack('<I', sb['block_size'])
        sb_data[16:20] = struct.pack('<I', sb['block_count'])
        sb_data[20:24] = struct.pack('<I', sb['inode_count'])
        sb_data[24:28] = struct.pack('<I', sb['free_blocks'])
        sb_data[28:32] = struct.pack('<I', sb['free_inodes'])
        sb_data[32:36] = struct.pack('<I', sb['root_inode'])
        sb_data[40:48] = struct.pack('<Q', sb['creation_time'])
        sb_data[48:52] = struct.pack('<I', sb['block_bitmap_start'])
        sb_data[52:56] = struct.pack('<I', sb['inode_bitmap_start'])
        sb_data[56:60] = struct.pack('<I', sb['inode_table_start'])
        sb_data[60:64] = struct.pack('<I', sb['data_start'])

        self.fd.seek(BLOCK_SIZE)
        self.fd.write(sb_data)

    def read_inode(self, inode_num):
        """Read inode from disk"""
        inode_offset = inode_num * 128  # Inode size is 128 bytes
        block_num = self.superblock['inode_table_start'] + (inode_offset // BLOCK_SIZE)
        offset_in_block = inode_offset % BLOCK_SIZE

        self.fd.seek(block_num * BLOCK_SIZE + offset_in_block)
        inode_data = self.fd.read(128)

        # Parse inode (matching Zig struct layout)
        blocks = []
        for i in range(DIRECT_BLOCKS):
            block_ptr = struct.unpack('<I', inode_data[40 + i*4:44 + i*4])[0]
            blocks.append(block_ptr)

        return {
            'id': struct.unpack('<I', inode_data[0:4])[0],
            'type': inode_data[4],
            'mode': struct.unpack('<H', inode_data[6:8])[0],
            'size': struct.unpack('<I', inode_data[8:12])[0],
            'blocks': blocks,
            'single_indirect': struct.unpack('<I', inode_data[88:92])[0],
            'double_indirect': struct.unpack('<I', inode_data[92:96])[0],
            'triple_indirect': struct.unpack('<I', inode_data[96:100])[0],
        }

    def write_inode(self, inode_num, inode):
        """Write inode to disk"""
        inode_offset = inode_num * 128
        block_num = self.superblock['inode_table_start'] + (inode_offset // BLOCK_SIZE)
        offset_in_block = inode_offset % BLOCK_SIZE

        # Pack inode data
        inode_data = bytearray(128)
        inode_data[0:4] = struct.pack('<I', inode['id'])
        inode_data[4] = inode['type']
        inode_data[6:8] = struct.pack('<H', inode['mode'])
        inode_data[8:12] = struct.pack('<I', inode['size'])
        inode_data[12:14] = struct.pack('<H', inode.get('uid', 0))
        inode_data[14:16] = struct.pack('<H', inode.get('gid', 0))
        inode_data[16:18] = struct.pack(
            '<H', inode.get('nlink', 2 if inode['type'] == ZFS_TYPE_DIRECTORY else 1)
        )
        inode_data[24:32] = struct.pack('<Q', inode.get('created', 0))
        inode_data[32:40] = struct.pack('<Q', inode.get('modified', 0))

        for i, block_ptr in enumerate(inode['blocks']):
            inode_data[40 + i*4:44 + i*4] = struct.pack('<I', block_ptr)
        inode_data[88:92] = struct.pack('<I', inode.get('single_indirect', 0))
        inode_data[92:96] = struct.pack('<I', inode.get('double_indirect', 0))
        inode_data[96:100] = struct.pack('<I', inode.get('triple_indirect', 0))

        self.fd.seek(block_num * BLOCK_SIZE + offset_in_block)
        self.fd.write(inode_data)

    def read_block(self, block_num):
        """Read a data block"""
        self.fd.seek(block_num * BLOCK_SIZE)
        return self.fd.read(BLOCK_SIZE)

    def write_block(self, block_num, data):
        """Write a data block"""
        self.fd.seek(block_num * BLOCK_SIZE)
        self.fd.write(data)

    def alloc_block(self):
        """Allocate a new data block"""
        # Read block bitmap
        self.fd.seek(self.superblock['block_bitmap_start'] * BLOCK_SIZE)
        bitmap = bytearray(self.fd.read(BLOCK_SIZE))

        # Find free block (starting from data_start)
        for i in range(self.superblock['data_start'], self.superblock['block_count']):
            byte_idx = i // 8
            bit_idx = i % 8

            if not (bitmap[byte_idx] & (1 << bit_idx)):
                # Mark as used
                bitmap[byte_idx] |= (1 << bit_idx)

                # Write back bitmap
                self.fd.seek(self.superblock['block_bitmap_start'] * BLOCK_SIZE)
                self.fd.write(bitmap)
                self.superblock['free_blocks'] -= 1
                self.write_superblock()

                # Clear the block
                self.fd.seek(i * BLOCK_SIZE)
                self.fd.write(b'\x00' * BLOCK_SIZE)

                return i

        raise RuntimeError("No free blocks available")

    def alloc_inode(self):
        """Allocate a new inode"""
        # Read inode bitmap
        self.fd.seek(self.superblock['inode_bitmap_start'] * BLOCK_SIZE)
        bitmap = bytearray(self.fd.read(BLOCK_SIZE))

        # Find free inode (skip root inode 0)
        for i in range(1, self.superblock['inode_count']):
            byte_idx = i // 8
            bit_idx = i % 8

            if not (bitmap[byte_idx] & (1 << bit_idx)):
                # Mark as used
                bitmap[byte_idx] |= (1 << bit_idx)

                # Write back bitmap
                self.fd.seek(self.superblock['inode_bitmap_start'] * BLOCK_SIZE)
                self.fd.write(bitmap)
                self.superblock['free_inodes'] -= 1
                self.write_superblock()

                return i

        raise RuntimeError("No free inodes available")

    def get_data_block(self, inode, logical_block):
        """Resolve a logical block number through direct or single-indirect pointers."""
        if inode['double_indirect'] != 0 or inode['triple_indirect'] != 0:
            raise ValueError("Double/triple indirect blocks are not supported")

        if logical_block < DIRECT_BLOCKS:
            return inode['blocks'][logical_block]

        indirect_index = logical_block - DIRECT_BLOCKS
        if indirect_index >= SINGLE_INDIRECT_BLOCKS:
            raise ValueError(f"Logical block {logical_block} is out of range")
        if inode['single_indirect'] == 0:
            return 0

        indirect = self.read_block(inode['single_indirect'])
        return struct.unpack_from('<I', indirect, indirect_index * 4)[0]

    def allocate_data_block(self, inode, logical_block):
        """Return an allocated data block, creating indirect metadata as needed."""
        if inode['double_indirect'] != 0 or inode['triple_indirect'] != 0:
            raise ValueError("Double/triple indirect blocks are not supported")

        if logical_block < DIRECT_BLOCKS:
            if inode['blocks'][logical_block] == 0:
                inode['blocks'][logical_block] = self.alloc_block()
            return inode['blocks'][logical_block]

        indirect_index = logical_block - DIRECT_BLOCKS
        if indirect_index >= SINGLE_INDIRECT_BLOCKS:
            raise ValueError(f"File exceeds {MAX_FILE_SIZE} bytes")

        if inode['single_indirect'] == 0:
            inode['single_indirect'] = self.alloc_block()

        indirect = bytearray(self.read_block(inode['single_indirect']))
        block_num = struct.unpack_from('<I', indirect, indirect_index * 4)[0]
        if block_num == 0:
            block_num = self.alloc_block()
            struct.pack_into('<I', indirect, indirect_index * 4, block_num)
            self.write_block(inode['single_indirect'], bytes(indirect))

        return block_num

    def add_dir_entry(self, parent_inode_num, name, inode_num):
        """Add a directory entry to parent directory"""
        parent_inode = self.read_inode(parent_inode_num)

        if parent_inode['type'] != ZFS_TYPE_DIRECTORY:
            raise ValueError("Parent is not a directory")

        block_count = (parent_inode['size'] + BLOCK_SIZE - 1) // BLOCK_SIZE
        if block_count > MAX_LOGICAL_BLOCKS:
            block_count = MAX_LOGICAL_BLOCKS

        # Search all existing directory blocks, including the indirect block.
        for logical_block in range(block_count):
            block_num = self.get_data_block(parent_inode, logical_block)
            if block_num == 0:
                block_num = self.allocate_data_block(parent_inode, logical_block)

            # Read directory block
            block_data = bytearray(self.read_block(block_num))

            # Find free entry
            for offset in range(0, BLOCK_SIZE, 32):  # DirEntry is 32 bytes
                entry_inode = struct.unpack('<I', block_data[offset+24:offset+28])[0]

                if entry_inode == 0:  # Free entry
                    # Write new entry
                    name_bytes = name.encode('utf-8')[:MAX_NAME_LEN]
                    block_data[offset:offset+len(name_bytes)] = name_bytes
                    block_data[offset+24:offset+28] = struct.pack('<I', inode_num)

                    # Write block back
                    self.write_block(block_num, bytes(block_data))

                    # Update parent inode
                    self.write_inode(parent_inode_num, parent_inode)
                    return

        if block_count >= MAX_LOGICAL_BLOCKS:
            raise RuntimeError("Directory is full")

        logical_block = block_count
        block_num = self.allocate_data_block(parent_inode, logical_block)
        parent_inode['size'] = (logical_block + 1) * BLOCK_SIZE
        block_data = bytearray(BLOCK_SIZE)
        name_bytes = name.encode('utf-8')[:MAX_NAME_LEN]
        block_data[0:len(name_bytes)] = name_bytes
        block_data[24:28] = struct.pack('<I', inode_num)
        self.write_block(block_num, bytes(block_data))
        self.write_inode(parent_inode_num, parent_inode)

    def create_file(self, parent_inode_num, name, content):
        """Create a file with content"""
        if len(content) > MAX_FILE_SIZE:
            raise ValueError(
                f"File '{name}' is too large: {len(content)} bytes "
                f"(max {MAX_FILE_SIZE})"
            )

        # Allocate inode
        inode_num = self.alloc_inode()

        # Allocate blocks for content
        blocks = []
        indirect_blocks = []
        remaining = content
        while remaining:
            block_num = self.alloc_block()
            if len(blocks) < DIRECT_BLOCKS:
                blocks.append(block_num)
            else:
                indirect_blocks.append(block_num)

            # Write content to block
            chunk = remaining[:BLOCK_SIZE]
            self.fd.seek(block_num * BLOCK_SIZE)
            self.fd.write(chunk.ljust(BLOCK_SIZE, b'\x00'))

            remaining = remaining[BLOCK_SIZE:]

        single_indirect = 0
        if indirect_blocks:
            single_indirect = self.alloc_block()
            indirect_data = bytearray(BLOCK_SIZE)
            for index, block_num in enumerate(indirect_blocks):
                struct.pack_into('<I', indirect_data, index * 4, block_num)
            self.write_block(single_indirect, bytes(indirect_data))

        # Create inode
        inode = {
            'id': inode_num,
            'type': ZFS_TYPE_REGULAR,
            'mode': 0o755,
            'size': len(content),
            'blocks': blocks + [0] * (DIRECT_BLOCKS - len(blocks)),
            'single_indirect': single_indirect,
            'double_indirect': 0,
            'triple_indirect': 0,
        }

        self.write_inode(inode_num, inode)

        # Add directory entry
        self.add_dir_entry(parent_inode_num, name, inode_num)

        return inode_num

    def create_directory(self, parent_inode_num, name):
        """Create a new directory"""
        # Allocate inode
        inode_num = self.alloc_inode()

        # Allocate block for directory entries
        block_num = self.alloc_block()

        # Create . and .. entries
        dir_data = bytearray(BLOCK_SIZE)

        # Entry . (points to self)
        dir_data[0:1] = b'.'
        dir_data[24:28] = struct.pack('<I', inode_num)

        # Entry .. (points to parent)
        dir_data[32:34] = b'..'
        dir_data[56:60] = struct.pack('<I', parent_inode_num)

        self.write_block(block_num, bytes(dir_data))

        # Create inode
        inode = {
            'id': inode_num,
            'type': ZFS_TYPE_DIRECTORY,
            'mode': 0o755 | 0o040000,  # S_IFDIR
            'size': BLOCK_SIZE,
            'blocks': [block_num] + [0] * (DIRECT_BLOCKS - 1),
            'single_indirect': 0,
            'double_indirect': 0,
            'triple_indirect': 0,
        }

        self.write_inode(inode_num, inode)

        # Add directory entry to parent
        self.add_dir_entry(parent_inode_num, name, inode_num)

        return inode_num

    def copy_recursive(self, source_dir, target_inode_num=0, target_path="/"):
        """Recursively copy directory contents to ZFS"""
        source_path = Path(source_dir)

        for item in source_path.iterdir():
            name = item.name

            if item.is_dir():
                print(f"  Creating directory: {target_path}{name}/")
                new_inode = self.create_directory(target_inode_num, name)
                self.copy_recursive(item, new_inode, f"{target_path}{name}/")
            else:
                print(f"  Copying file: {target_path}{name} ({item.stat().st_size} bytes)")
                with open(item, 'rb') as f:
                    content = f.read()
                self.create_file(target_inode_num, name, content)

    def close(self):
        """Close the image file"""
        if self.fd:
            self.fd.close()

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    image_path = sys.argv[1]
    source_dir = sys.argv[2]
    target_path = sys.argv[3] if len(sys.argv) > 3 else "/"

    if not os.path.exists(image_path):
        print(f"Error: Image file not found: {image_path}")
        sys.exit(1)

    if not os.path.isdir(source_dir):
        print(f"Error: Source directory not found: {source_dir}")
        sys.exit(1)

    print(f"Populating ZFS image: {image_path}")
    print(f"Source: {source_dir}")
    print(f"Target: {target_path}")
    print()

    try:
        zfs = ZFSImage(image_path)

        # Find target inode
        if target_path == "/":
            target_inode = 0  # Root inode
        else:
            # TODO: Walk path to find target inode
            print(f"Warning: Non-root target not implemented, using root")
            target_inode = 0

        # Copy files
        zfs.copy_recursive(source_dir, target_inode, target_path)

        print()
        print("ZFS image populated successfully!")

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        if 'zfs' in locals():
            zfs.close()

if __name__ == "__main__":
    main()
