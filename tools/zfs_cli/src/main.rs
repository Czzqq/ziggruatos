// zfs_cli - ZFS (Ziggurat File System) CLI inspection tool
//
// Host-side x86 tool for reading and inspecting ZFS disk images.
//
// Usage:
//   zfs_cli <disk_image> info              - Show filesystem information
//   zfs_cli <disk_image> ls [path]         - List directory contents
//   zfs_cli <disk_image> stat <path>       - Show file/directory details
//   zfs_cli <disk_image> usage             - Show disk usage statistics
//   zfs_cli <disk_image> cat <path>        - Dump file contents
//   zfs_cli <disk_image> tree [path]       - Show directory tree
//   zfs_cli <disk_image> dump <block>      - Dump raw block data
//   zfs_cli <disk_image> inode <num>       - Show raw inode data

use std::env;
use std::fs::File;
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};

// ============================================================================
// Constants
// ============================================================================

const BLOCK_SIZE: usize = 4096;
const ZFS_MAGIC: u64 = 0x5A495353554D4F21; // "ZIGSUM!"
const ZFS_VERSION: u32 = 2;
const MAX_NAME_LEN: usize = 24;
const DIRECT_BLOCKS: usize = 12;
const PTRS_PER_BLOCK: usize = BLOCK_SIZE / 4;
const SINGLE_INDIRECT_BLOCKS: usize = PTRS_PER_BLOCK;
const MAX_LOGICAL_BLOCKS: usize = DIRECT_BLOCKS + SINGLE_INDIRECT_BLOCKS;
const MAX_FILE_SIZE: usize = MAX_LOGICAL_BLOCKS * BLOCK_SIZE;
const INODE_SIZE: usize = 128;
const DIRENT_SIZE: usize = 32;

// File types
const ZFS_TYPE_FREE: u8 = 0;
const ZFS_TYPE_REGULAR: u8 = 1;
const ZFS_TYPE_DIRECTORY: u8 = 2;

// ============================================================================
// On-Disk Structures
// ============================================================================

#[derive(Debug, Clone)]
struct SuperBlock {
    magic: u64,
    version: u32,
    block_size: u32,
    block_count: u32,
    inode_count: u32,
    free_blocks: u32,
    free_inodes: u32,
    root_inode: u32,
    creation_time: u64,
    block_bitmap_start: u32,
    inode_bitmap_start: u32,
    inode_table_start: u32,
    data_start: u32,
}

#[derive(Debug, Clone)]
struct Inode {
    id: u32,
    type_: u8,
    mode: u16,
    size: u32,
    uid: u16,
    gid: u16,
    nlink: u16,
    created: u64,
    modified: u64,
    blocks: [u32; DIRECT_BLOCKS],
    single_indirect: u32,
    double_indirect: u32,
    triple_indirect: u32,
}

#[derive(Debug, Clone)]
struct DirEntry {
    name: String,
    inode: u32,
}

// ============================================================================
// Low-level read helpers
// ============================================================================

fn read_u8(buf: &[u8], offset: usize) -> u8 {
    buf[offset]
}

fn read_u16(buf: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([buf[offset], buf[offset + 1]])
}

fn read_u32(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
    ])
}

fn read_u64(buf: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
        buf[offset + 4],
        buf[offset + 5],
        buf[offset + 6],
        buf[offset + 7],
    ])
}

// ============================================================================
// ZFS Image Reader
// ============================================================================

struct ZfsImage {
    file: File,
    superblock: SuperBlock,
}

impl ZfsImage {
    fn open(path: &str) -> Result<Self, String> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| format!("Cannot open '{}': {}", path, e))?;

        // Read superblock (at block 1, offset 4096)
        let mut sb_buf = [0u8; BLOCK_SIZE];
        file.seek(SeekFrom::Start(BLOCK_SIZE as u64))
            .map_err(|e| format!("Seek failed: {}", e))?;
        file.read_exact(&mut sb_buf)
            .map_err(|e| format!("Cannot read superblock: {}", e))?;

        let superblock = Self::parse_superblock(&sb_buf);

        if superblock.magic != ZFS_MAGIC {
            return Err(format!(
                "Invalid ZFS magic: 0x{:016X} (expected 0x{:016X})",
                superblock.magic, ZFS_MAGIC
            ));
        }

        if superblock.version != ZFS_VERSION {
            return Err(format!(
                "Unsupported ZFS version: {} (expected {})",
                superblock.version, ZFS_VERSION
            ));
        }

        Ok(ZfsImage { file, superblock })
    }

    fn parse_superblock(buf: &[u8]) -> SuperBlock {
        SuperBlock {
            magic: read_u64(buf, 0),
            version: read_u32(buf, 8),
            block_size: read_u32(buf, 12),
            block_count: read_u32(buf, 16),
            inode_count: read_u32(buf, 20),
            free_blocks: read_u32(buf, 24),
            free_inodes: read_u32(buf, 28),
            root_inode: read_u32(buf, 32),
            // 4 bytes padding at offset 36-39
            creation_time: read_u64(buf, 40),
            block_bitmap_start: read_u32(buf, 48),
            inode_bitmap_start: read_u32(buf, 52),
            inode_table_start: read_u32(buf, 56),
            data_start: read_u32(buf, 60),
        }
    }

    fn read_block(&mut self, block_num: u32) -> Result<[u8; BLOCK_SIZE], String> {
        if block_num >= self.superblock.block_count {
            return Err(format!(
                "Block {} out of range (max {})",
                block_num,
                self.superblock.block_count - 1
            ));
        }
        let mut buf = [0u8; BLOCK_SIZE];
        self.file
            .seek(SeekFrom::Start(block_num as u64 * BLOCK_SIZE as u64))
            .map_err(|e| format!("Seek to block {} failed: {}", block_num, e))?;
        self.file
            .read_exact(&mut buf)
            .map_err(|e| format!("Read block {} failed: {}", block_num, e))?;
        Ok(buf)
    }

    fn read_inode(&mut self, inode_num: u32) -> Result<Inode, String> {
        if inode_num >= self.superblock.inode_count {
            return Err(format!(
                "Inode {} out of range (max {})",
                inode_num,
                self.superblock.inode_count - 1
            ));
        }

        let inode_offset = inode_num as usize * INODE_SIZE;
        let block_num = self.superblock.inode_table_start + (inode_offset / BLOCK_SIZE) as u32;
        let offset_in_block = inode_offset % BLOCK_SIZE;

        let buf = self.read_block(block_num)?;

        let mut blocks = [0u32; DIRECT_BLOCKS];
        for i in 0..DIRECT_BLOCKS {
            blocks[i] = read_u32(&buf, offset_in_block + 40 + i * 4);
        }

        Ok(Inode {
            id: read_u32(&buf, offset_in_block),
            type_: read_u8(&buf, offset_in_block + 4),
            mode: read_u16(&buf, offset_in_block + 6),
            size: read_u32(&buf, offset_in_block + 8),
            uid: read_u16(&buf, offset_in_block + 12),
            gid: read_u16(&buf, offset_in_block + 14),
            nlink: read_u16(&buf, offset_in_block + 16),
            created: read_u64(&buf, offset_in_block + 24),
            modified: read_u64(&buf, offset_in_block + 32),
            blocks,
            single_indirect: read_u32(&buf, offset_in_block + 88),
            double_indirect: read_u32(&buf, offset_in_block + 92),
            triple_indirect: read_u32(&buf, offset_in_block + 96),
        })
    }

    fn data_blocks(&mut self, inode: &Inode) -> Result<Vec<(usize, u32)>, String> {
        if inode.double_indirect != 0 || inode.triple_indirect != 0 {
            return Err("Double/triple indirect blocks are not supported".to_string());
        }

        let mut blocks = Vec::new();
        for (logical_block, &block_num) in inode.blocks.iter().enumerate() {
            if block_num != 0 {
                blocks.push((logical_block, block_num));
            }
        }

        if inode.single_indirect != 0 {
            let buf = self.read_block(inode.single_indirect)?;
            for indirect_index in 0..SINGLE_INDIRECT_BLOCKS {
                let block_num = read_u32(&buf, indirect_index * 4);
                if block_num != 0 {
                    blocks.push((DIRECT_BLOCKS + indirect_index, block_num));
                }
            }
        }

        Ok(blocks)
    }

    fn allocate_data_block(
        &mut self,
        inode: &mut Inode,
        logical_block: usize,
    ) -> Result<u32, String> {
        if logical_block < DIRECT_BLOCKS {
            if inode.blocks[logical_block] == 0 {
                inode.blocks[logical_block] = self.alloc_block()?;
            }
            return Ok(inode.blocks[logical_block]);
        }

        let indirect_index = logical_block - DIRECT_BLOCKS;
        if indirect_index >= SINGLE_INDIRECT_BLOCKS {
            return Err(format!("File too large (max {} bytes)", MAX_FILE_SIZE));
        }

        if inode.single_indirect == 0 {
            inode.single_indirect = self.alloc_block()?;
        }

        let mut indirect = self.read_block(inode.single_indirect)?;
        let offset = indirect_index * 4;
        let mut block_num = read_u32(&indirect, offset);
        if block_num == 0 {
            block_num = self.alloc_block()?;
            indirect[offset..offset + 4].copy_from_slice(&block_num.to_le_bytes());
            self.write_block(inode.single_indirect, &indirect)?;
        }
        Ok(block_num)
    }

    fn data_block(&mut self, inode: &Inode, logical_block: usize) -> Result<u32, String> {
        if inode.double_indirect != 0 || inode.triple_indirect != 0 {
            return Err("Double/triple indirect blocks are not supported".to_string());
        }

        if logical_block < DIRECT_BLOCKS {
            return Ok(inode.blocks[logical_block]);
        }

        let indirect_index = logical_block - DIRECT_BLOCKS;
        if indirect_index >= SINGLE_INDIRECT_BLOCKS {
            return Err(format!("Logical block {} is out of range", logical_block));
        }
        if inode.single_indirect == 0 {
            return Ok(0);
        }

        let indirect = self.read_block(inode.single_indirect)?;
        Ok(read_u32(&indirect, indirect_index * 4))
    }

    fn clear_block_pointers(inode: &mut Inode) {
        inode.blocks = [0u32; DIRECT_BLOCKS];
        inode.single_indirect = 0;
        inode.double_indirect = 0;
        inode.triple_indirect = 0;
    }

    fn free_file_blocks(&mut self, inode: &Inode) -> Result<(), String> {
        if inode.double_indirect != 0 || inode.triple_indirect != 0 {
            return Err("Double/triple indirect blocks are not supported".to_string());
        }

        for &block_num in &inode.blocks {
            if block_num != 0 {
                self.free_block(block_num)?;
            }
        }

        if inode.single_indirect != 0 {
            let indirect = self.read_block(inode.single_indirect)?;
            for indirect_index in 0..SINGLE_INDIRECT_BLOCKS {
                let block_num = read_u32(&indirect, indirect_index * 4);
                if block_num != 0 {
                    self.free_block(block_num)?;
                }
            }
            self.free_block(inode.single_indirect)?;
        }

        Ok(())
    }

    fn read_file_data(&mut self, inode: &Inode) -> Result<Vec<u8>, String> {
        if inode.type_ != ZFS_TYPE_REGULAR {
            return Err("Not a regular file".to_string());
        }

        let mut data = vec![0u8; inode.size as usize];
        let block_count = (data.len() + BLOCK_SIZE - 1) / BLOCK_SIZE;
        for (logical_block, block_num) in self.data_blocks(inode)? {
            if logical_block >= block_count {
                break;
            }

            let buf = self.read_block(block_num)?;
            let offset = logical_block * BLOCK_SIZE;
            let len = std::cmp::min(BLOCK_SIZE, data.len() - offset);
            data[offset..offset + len].copy_from_slice(&buf[..len]);
        }
        Ok(data)
    }

    fn write_file_data(&mut self, inode: &mut Inode, data: &[u8]) -> Result<(), String> {
        if data.len() > MAX_FILE_SIZE {
            return Err(format!(
                "File too large ({} bytes, max {} bytes)",
                data.len(),
                MAX_FILE_SIZE
            ));
        }

        let mut offset = 0;
        while offset < data.len() {
            let logical_block = offset / BLOCK_SIZE;
            let block_offset = offset % BLOCK_SIZE;
            let to_write = std::cmp::min(BLOCK_SIZE - block_offset, data.len() - offset);
            let block_num = self.allocate_data_block(inode, logical_block)?;

            let mut buf = self.read_block(block_num)?;
            buf[block_offset..block_offset + to_write]
                .copy_from_slice(&data[offset..offset + to_write]);
            self.write_block(block_num, &buf)?;
            offset += to_write;
        }

        inode.size = data.len() as u32;
        self.write_inode(inode)
    }

    fn read_dir_entries(&mut self, inode: &Inode) -> Result<Vec<DirEntry>, String> {
        if inode.type_ != ZFS_TYPE_DIRECTORY {
            return Err("Not a directory".to_string());
        }

        let mut entries = Vec::new();

        for (_, block_num) in self.data_blocks(inode)? {
            let buf = self.read_block(block_num)?;

            let mut offset = 0;
            while offset < BLOCK_SIZE {
                let entry_inode = read_u32(&buf, offset + MAX_NAME_LEN);

                if entry_inode != 0 {
                    // Read name (null-terminated or up to MAX_NAME_LEN)
                    let name_end = (offset..offset + MAX_NAME_LEN)
                        .find(|&i| buf[i] == 0)
                        .unwrap_or(offset + MAX_NAME_LEN);
                    let name = String::from_utf8_lossy(&buf[offset..name_end]).to_string();

                    entries.push(DirEntry {
                        name,
                        inode: entry_inode,
                    });
                }

                offset += DIRENT_SIZE;
            }
        }

        Ok(entries)
    }

    fn resolve_path(&mut self, path: &str) -> Result<Inode, String> {
        let path = path.trim_end_matches('/');
        if path.is_empty() || path == "/" {
            return self.read_inode(self.superblock.root_inode);
        }

        let components: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
        let mut current = self.read_inode(self.superblock.root_inode)?;

        for component in &components {
            if current.type_ != ZFS_TYPE_DIRECTORY {
                return Err(format!("'{}' is not a directory", component));
            }

            let entries = self.read_dir_entries(&current)?;
            let found = entries.iter().find(|e| e.name == *component);

            match found {
                Some(entry) => {
                    current = self.read_inode(entry.inode)?;
                }
                None => return Err(format!("'{}' not found", path)),
            }
        }

        Ok(current)
    }

    fn read_inode_bitmap(&mut self) -> Result<Vec<u8>, String> {
        let bitmap_blocks = (self.superblock.inode_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();

        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.inode_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        Ok(bitmap)
    }

    fn read_block_bitmap(&mut self) -> Result<Vec<u8>, String> {
        let bitmap_blocks = (self.superblock.block_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();

        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.block_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        Ok(bitmap)
    }

    // ========================================================================
    // Write operations
    // ========================================================================

    fn write_block(&mut self, block_num: u32, buf: &[u8; BLOCK_SIZE]) -> Result<(), String> {
        if block_num >= self.superblock.block_count {
            return Err(format!(
                "Block {} out of range (max {})",
                block_num,
                self.superblock.block_count - 1
            ));
        }
        self.file
            .seek(SeekFrom::Start(block_num as u64 * BLOCK_SIZE as u64))
            .map_err(|e| format!("Seek to block {} failed: {}", block_num, e))?;
        self.file
            .write_all(buf)
            .map_err(|e| format!("Write block {} failed: {}", block_num, e))?;
        Ok(())
    }

    fn write_inode(&mut self, inode: &Inode) -> Result<(), String> {
        let inode_num = inode.id;
        if inode_num >= self.superblock.inode_count {
            return Err(format!(
                "Inode {} out of range (max {})",
                inode_num,
                self.superblock.inode_count - 1
            ));
        }

        let inode_offset = inode_num as usize * INODE_SIZE;
        let block_num = self.superblock.inode_table_start + (inode_offset / BLOCK_SIZE) as u32;
        let offset_in_block = inode_offset % BLOCK_SIZE;

        // Read existing block, patch inode, write back
        let mut buf = self.read_block(block_num)?;

        // Serialize inode into the block
        let o = offset_in_block;
        buf[o..o + 4].copy_from_slice(&inode.id.to_le_bytes());
        buf[o + 4] = inode.type_;
        buf[o + 5] = 0; // pad
        buf[o + 6..o + 8].copy_from_slice(&inode.mode.to_le_bytes());
        buf[o + 8..o + 12].copy_from_slice(&inode.size.to_le_bytes());
        buf[o + 12..o + 14].copy_from_slice(&inode.uid.to_le_bytes());
        buf[o + 14..o + 16].copy_from_slice(&inode.gid.to_le_bytes());
        buf[o + 16..o + 18].copy_from_slice(&inode.nlink.to_le_bytes());
        // pad[6] at o+18..o+24
        buf[o + 24..o + 32].copy_from_slice(&inode.created.to_le_bytes());
        buf[o + 32..o + 40].copy_from_slice(&inode.modified.to_le_bytes());
        for i in 0..DIRECT_BLOCKS {
            buf[o + 40 + i * 4..o + 44 + i * 4].copy_from_slice(&inode.blocks[i].to_le_bytes());
        }
        buf[o + 88..o + 92].copy_from_slice(&inode.single_indirect.to_le_bytes());
        buf[o + 92..o + 96].copy_from_slice(&inode.double_indirect.to_le_bytes());
        buf[o + 96..o + 100].copy_from_slice(&inode.triple_indirect.to_le_bytes());
        // reserved[7] at o+100..o+128 is already from existing block

        self.write_block(block_num, &buf)
    }

    fn write_superblock(&mut self) -> Result<(), String> {
        let mut buf = [0u8; BLOCK_SIZE];
        let sb = &self.superblock;

        buf[0..8].copy_from_slice(&sb.magic.to_le_bytes());
        buf[8..12].copy_from_slice(&sb.version.to_le_bytes());
        buf[12..16].copy_from_slice(&sb.block_size.to_le_bytes());
        buf[16..20].copy_from_slice(&sb.block_count.to_le_bytes());
        buf[20..24].copy_from_slice(&sb.inode_count.to_le_bytes());
        buf[24..28].copy_from_slice(&sb.free_blocks.to_le_bytes());
        buf[28..32].copy_from_slice(&sb.free_inodes.to_le_bytes());
        buf[32..36].copy_from_slice(&sb.root_inode.to_le_bytes());
        // 4 bytes padding at 36..40
        buf[40..48].copy_from_slice(&sb.creation_time.to_le_bytes());
        buf[48..52].copy_from_slice(&sb.block_bitmap_start.to_le_bytes());
        buf[52..56].copy_from_slice(&sb.inode_bitmap_start.to_le_bytes());
        buf[56..60].copy_from_slice(&sb.inode_table_start.to_le_bytes());
        buf[60..64].copy_from_slice(&sb.data_start.to_le_bytes());

        self.write_block(1, &buf)
    }

    fn alloc_block(&mut self) -> Result<u32, String> {
        let bitmap_blocks = (self.superblock.block_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();
        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.block_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        // Find a free block in the data range
        for i in self.superblock.data_start..self.superblock.block_count {
            let idx = i as usize;
            let byte_idx = idx / 8;
            let bit_idx = idx % 8;
            if byte_idx < bitmap.len() && (bitmap[byte_idx] & (1 << bit_idx)) == 0 {
                // Mark as used
                bitmap[byte_idx] |= 1 << bit_idx;

                // Write bitmap back
                for j in 0..bitmap_blocks as u32 {
                    let mut block_buf = [0u8; BLOCK_SIZE];
                    let offset = j as usize * BLOCK_SIZE;
                    let remaining = bitmap.len() - offset;
                    let len = std::cmp::min(BLOCK_SIZE, remaining);
                    block_buf[..len].copy_from_slice(&bitmap[offset..offset + len]);
                    self.write_block(self.superblock.block_bitmap_start + j, &block_buf)?;
                }

                self.superblock.free_blocks -= 1;
                self.write_superblock()?;

                // Zero out the allocated block
                let zero = [0u8; BLOCK_SIZE];
                self.write_block(i, &zero)?;

                return Ok(i);
            }
        }
        Err("No free blocks available".to_string())
    }

    fn alloc_inode(&mut self) -> Result<u32, String> {
        let bitmap_blocks = (self.superblock.inode_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();
        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.inode_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        // Find a free inode (skip inode 0 = root)
        for i in 1..self.superblock.inode_count {
            let idx = i as usize;
            let byte_idx = idx / 8;
            let bit_idx = idx % 8;
            if byte_idx < bitmap.len() && (bitmap[byte_idx] & (1 << bit_idx)) == 0 {
                // Mark as used
                bitmap[byte_idx] |= 1 << bit_idx;

                // Write bitmap back
                for j in 0..bitmap_blocks as u32 {
                    let mut block_buf = [0u8; BLOCK_SIZE];
                    let offset = j as usize * BLOCK_SIZE;
                    let remaining = bitmap.len() - offset;
                    let len = std::cmp::min(BLOCK_SIZE, remaining);
                    block_buf[..len].copy_from_slice(&bitmap[offset..offset + len]);
                    self.write_block(self.superblock.inode_bitmap_start + j, &block_buf)?;
                }

                self.superblock.free_inodes -= 1;
                self.write_superblock()?;

                return Ok(i);
            }
        }
        Err("No free inodes available".to_string())
    }

    fn free_block(&mut self, block_num: u32) -> Result<(), String> {
        if block_num < self.superblock.data_start {
            return Err("Cannot free metadata block".to_string());
        }

        let bitmap_blocks = (self.superblock.block_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();
        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.block_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        let idx = block_num as usize;
        let byte_idx = idx / 8;
        let bit_idx = idx % 8;
        if byte_idx < bitmap.len() {
            bitmap[byte_idx] &= !(1 << bit_idx);
        }

        for j in 0..bitmap_blocks as u32 {
            let mut block_buf = [0u8; BLOCK_SIZE];
            let offset = j as usize * BLOCK_SIZE;
            let remaining = bitmap.len() - offset;
            let len = std::cmp::min(BLOCK_SIZE, remaining);
            block_buf[..len].copy_from_slice(&bitmap[offset..offset + len]);
            self.write_block(self.superblock.block_bitmap_start + j, &block_buf)?;
        }

        self.superblock.free_blocks += 1;
        self.write_superblock()
    }

    fn free_inode(&mut self, inode_num: u32) -> Result<(), String> {
        if inode_num == 0 {
            return Err("Cannot free root inode".to_string());
        }

        let bitmap_blocks = (self.superblock.inode_count as usize + 7) / 8 / BLOCK_SIZE + 1;
        let mut bitmap = Vec::new();
        for i in 0..bitmap_blocks as u32 {
            let block = self.read_block(self.superblock.inode_bitmap_start + i)?;
            bitmap.extend_from_slice(&block);
        }

        let idx = inode_num as usize;
        let byte_idx = idx / 8;
        let bit_idx = idx % 8;
        if byte_idx < bitmap.len() {
            bitmap[byte_idx] &= !(1 << bit_idx);
        }

        for j in 0..bitmap_blocks as u32 {
            let mut block_buf = [0u8; BLOCK_SIZE];
            let offset = j as usize * BLOCK_SIZE;
            let remaining = bitmap.len() - offset;
            let len = std::cmp::min(BLOCK_SIZE, remaining);
            block_buf[..len].copy_from_slice(&bitmap[offset..offset + len]);
            self.write_block(self.superblock.inode_bitmap_start + j, &block_buf)?;
        }

        self.superblock.free_inodes += 1;
        self.write_superblock()
    }

    fn add_dir_entry(
        &mut self,
        parent_inode_num: u32,
        name: &str,
        child_inode_num: u32,
    ) -> Result<(), String> {
        let mut parent = self.read_inode(parent_inode_num)?;
        if parent.type_ != ZFS_TYPE_DIRECTORY {
            return Err("Parent is not a directory".to_string());
        }

        let name_bytes = name.as_bytes();
        if name_bytes.len() > MAX_NAME_LEN {
            return Err(format!("Name too long (max {} bytes)", MAX_NAME_LEN));
        }

        let existing_blocks =
            ((parent.size as usize + BLOCK_SIZE - 1) / BLOCK_SIZE).min(MAX_LOGICAL_BLOCKS);

        // Search existing directory blocks, including single-indirect blocks.
        for logical_block in 0..existing_blocks {
            let block_num = match self.data_block(&parent, logical_block)? {
                0 => self.allocate_data_block(&mut parent, logical_block)?,
                block_num => block_num,
            };
            let mut buf = self.read_block(block_num)?;

            // Scan for free slot
            let mut offset = 0;
            while offset < BLOCK_SIZE {
                let entry_inode = read_u32(&buf, offset + MAX_NAME_LEN);
                if entry_inode == 0 {
                    // Found a free slot, write the entry
                    // Clear the entry first
                    buf[offset..offset + DIRENT_SIZE].fill(0);
                    // Write name
                    buf[offset..offset + name_bytes.len()].copy_from_slice(name_bytes);
                    // Write inode number at offset + 24
                    buf[offset + MAX_NAME_LEN..offset + MAX_NAME_LEN + 4]
                        .copy_from_slice(&child_inode_num.to_le_bytes());

                    self.write_block(block_num, &buf)?;
                    self.write_inode(&parent)?;
                    return Ok(());
                }
                offset += DIRENT_SIZE;
            }
        }

        if existing_blocks >= MAX_LOGICAL_BLOCKS {
            return Err("Directory is full".to_string());
        }

        let new_block = self.allocate_data_block(&mut parent, existing_blocks)?;
        parent.size = ((existing_blocks + 1) * BLOCK_SIZE) as u32;
        let mut buf = [0u8; BLOCK_SIZE];
        buf[..name_bytes.len()].copy_from_slice(name_bytes);
        buf[MAX_NAME_LEN..MAX_NAME_LEN + 4].copy_from_slice(&child_inode_num.to_le_bytes());
        self.write_block(new_block, &buf)?;
        self.write_inode(&parent)
    }

    fn remove_dir_entry(&mut self, parent_inode_num: u32, name: &str) -> Result<u32, String> {
        let parent = self.read_inode(parent_inode_num)?;
        if parent.type_ != ZFS_TYPE_DIRECTORY {
            return Err("Parent is not a directory".to_string());
        }

        for (_, block_num) in self.data_blocks(&parent)? {
            let mut buf = self.read_block(block_num)?;

            let mut offset = 0;
            while offset < BLOCK_SIZE {
                let entry_inode = read_u32(&buf, offset + MAX_NAME_LEN);
                if entry_inode != 0 {
                    let name_end = (offset..offset + MAX_NAME_LEN)
                        .find(|&i| buf[i] == 0)
                        .unwrap_or(offset + MAX_NAME_LEN);
                    let entry_name = String::from_utf8_lossy(&buf[offset..name_end]).to_string();

                    if entry_name == name {
                        // Clear the entry
                        buf[offset..offset + DIRENT_SIZE].fill(0);
                        self.write_block(block_num, &buf)?;
                        return Ok(entry_inode);
                    }
                }
                offset += DIRENT_SIZE;
            }
        }

        Err(format!("'{}' not found in directory", name))
    }
}

// ============================================================================
// Formatting helpers
// ============================================================================

fn file_type_str(type_: u8) -> &'static str {
    match type_ {
        ZFS_TYPE_FREE => "free",
        ZFS_TYPE_REGULAR => "regular",
        ZFS_TYPE_DIRECTORY => "directory",
        _ => "unknown",
    }
}

fn format_mode(mode: u16, type_: u8) -> String {
    let perms = [
        (0o400, 'r'),
        (0o200, 'w'),
        (0o100, 'x'),
        (0o040, 'r'),
        (0o020, 'w'),
        (0o010, 'x'),
        (0o004, 'r'),
        (0o002, 'w'),
        (0o001, 'x'),
    ];

    let mut result = String::with_capacity(10);

    // File type prefix - use inode type_ if mode bits are missing
    if mode & 0o040000 != 0 || type_ == ZFS_TYPE_DIRECTORY {
        result.push('d');
    } else if mode & 0o100000 != 0 || type_ == ZFS_TYPE_REGULAR {
        result.push('-');
    } else {
        result.push('?');
    }

    // Permission bits
    for &(bit, ch) in &perms {
        if mode & bit != 0 {
            result.push(ch);
        } else {
            result.push('-');
        }
    }

    result
}

fn format_size(bytes: u32) -> String {
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

fn print_block_pointers(zfs: &mut ZfsImage, inode: &Inode) {
    println!("  Block pointers:");
    match zfs.data_blocks(inode) {
        Ok(blocks) => {
            if blocks.is_empty() {
                println!("    (none)");
            } else {
                for (logical_block, block_num) in blocks {
                    println!("    [{}] -> block {}", logical_block, block_num);
                }
            }
        }
        Err(e) => println!("    Error reading indirect blocks: {}", e),
    }

    if inode.single_indirect != 0 {
        println!("    indirect -> block {}", inode.single_indirect);
    }
    if inode.double_indirect != 0 {
        println!("    double indirect -> block {}", inode.double_indirect);
    }
    if inode.triple_indirect != 0 {
        println!("    triple indirect -> block {}", inode.triple_indirect);
    }
}

// ============================================================================
// Command implementations
// ============================================================================

fn cmd_info(zfs: &mut ZfsImage) {
    let sb = &zfs.superblock;

    println!("ZFS Filesystem Information");
    println!("==========================");
    println!(
        "  Magic:            0x{:016X}{}",
        sb.magic,
        if sb.magic == ZFS_MAGIC {
            " (valid)"
        } else {
            " (INVALID)"
        }
    );
    println!("  Version:          {}", sb.version);
    println!("  Block size:       {} bytes", sb.block_size);
    println!("  Total blocks:     {}", sb.block_count);
    println!(
        "  Total size:       {}",
        format_size(sb.block_count * sb.block_size)
    );
    println!();
    println!("  Inode count:      {}", sb.inode_count);
    println!("  Free inodes:      {}", sb.free_inodes);
    println!("  Used inodes:      {}", sb.inode_count - sb.free_inodes);
    println!();
    println!("  Free blocks:      {}", sb.free_blocks);
    println!("  Used blocks:      {}", sb.block_count - sb.free_blocks);
    println!(
        "  Usage:            {:.1}%",
        (sb.block_count - sb.free_blocks) as f64 / sb.block_count as f64 * 100.0
    );
    println!();
    println!("  Root inode:       {}", sb.root_inode);
    println!("  Creation time:    {}", sb.creation_time);
    println!();
    println!("Layout:");
    println!("  Block bitmap:     block {}", sb.block_bitmap_start);
    println!("  Inode bitmap:     block {}", sb.inode_bitmap_start);
    println!("  Inode table:      block {}", sb.inode_table_start);
    println!("  Data area:        block {}", sb.data_start);

    // Show root inode info
    match zfs.read_inode(sb.root_inode) {
        Ok(root) => {
            println!();
            println!("Root Directory:");
            println!("  Inode:            {}", root.id);
            println!("  Type:             {}", file_type_str(root.type_));
            println!(
                "  Mode:             {:o} ({})",
                root.mode,
                format_mode(root.mode, root.type_)
            );
            println!("  Size:             {} bytes", root.size);
            println!("  Links:            {}", root.nlink);
        }
        Err(e) => {
            println!("\n  Error reading root inode: {}", e);
        }
    }
}

fn cmd_ls(zfs: &mut ZfsImage, path: &str) {
    let inode = match zfs.resolve_path(path) {
        Ok(i) => i,
        Err(e) => {
            println!("ls: {}: {}", path, e);
            return;
        }
    };

    if inode.type_ != ZFS_TYPE_DIRECTORY {
        println!("ls: {}: Not a directory", path);
        return;
    }

    let entries = match zfs.read_dir_entries(&inode) {
        Ok(e) => e,
        Err(e) => {
            println!("ls: {}: {}", path, e);
            return;
        }
    };

    println!("{}:", path);
    for entry in &entries {
        match zfs.read_inode(entry.inode) {
            Ok(child_inode) => {
                let type_char = match child_inode.type_ {
                    ZFS_TYPE_DIRECTORY => "d",
                    ZFS_TYPE_REGULAR => "-",
                    _ => "?",
                };
                println!(
                    "{} {} {:>8} {}",
                    type_char,
                    format_mode(child_inode.mode, child_inode.type_),
                    child_inode.size,
                    entry.name
                );
            }
            Err(_) => {
                println!(
                    "? --------- {:>8} {} [inode {}]",
                    "?", entry.name, entry.inode
                );
            }
        }
    }
    println!("{} entries", entries.len());
}

fn cmd_stat(zfs: &mut ZfsImage, path: &str) {
    // Try to resolve as a path
    let inode = match zfs.resolve_path(path) {
        Ok(i) => i,
        Err(e) => {
            println!("stat: {}: {}", path, e);
            return;
        }
    };

    // Also try to get parent/name for the actual name
    let display_name = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(path);

    println!("  Path:             {}", path);
    println!("  Inode:            {}", inode.id);
    println!("  Type:             {}", file_type_str(inode.type_));
    println!(
        "  Mode:             {:o} ({})",
        inode.mode,
        format_mode(inode.mode, inode.type_)
    );
    println!(
        "  Size:             {} bytes ({})",
        inode.size,
        format_size(inode.size)
    );
    println!("  UID:              {}", inode.uid);
    println!("  GID:              {}", inode.gid);
    println!("  Links:            {}", inode.nlink);
    println!("  Created:          {}", inode.created);
    println!("  Modified:         {}", inode.modified);
    println!();
    print_block_pointers(zfs, &inode);

    if inode.type_ == ZFS_TYPE_DIRECTORY {
        println!();
        match zfs.read_dir_entries(&inode) {
            Ok(entries) => {
                println!("  Contains {} entries", entries.len());
            }
            Err(e) => {
                println!("  Error reading entries: {}", e);
            }
        }
    }

    let _ = display_name;
}

fn cmd_usage(zfs: &mut ZfsImage) {
    let block_count = zfs.superblock.block_count;
    let block_size = zfs.superblock.block_size;
    let free_blocks = zfs.superblock.free_blocks;
    let inode_count = zfs.superblock.inode_count;
    let free_inodes = zfs.superblock.free_inodes;

    println!("Disk Usage");
    println!("==========");
    println!();
    println!("Blocks:");
    println!(
        "  Total:            {} ({} bytes)",
        block_count,
        block_count * block_size
    );
    println!(
        "  Used:             {} ({})",
        block_count - free_blocks,
        format_size((block_count - free_blocks) * block_size)
    );
    println!(
        "  Free:             {} ({})",
        free_blocks,
        format_size(free_blocks * block_size)
    );
    println!(
        "  Usage:            {:.1}%",
        (block_count - free_blocks) as f64 / block_count as f64 * 100.0
    );
    println!();
    println!("Inodes:");
    println!("  Total:            {}", inode_count);
    println!("  Used:             {}", inode_count - free_inodes);
    println!("  Free:             {}", free_inodes);
    println!(
        "  Usage:            {:.1}%",
        (inode_count - free_inodes) as f64 / inode_count as f64 * 100.0
    );

    // Count actual used blocks/inodes from bitmaps
    println!();
    println!("Actual usage (from bitmaps):");

    match zfs.read_block_bitmap() {
        Ok(bitmap) => {
            let mut used_blocks: u32 = 0;
            for i in 0..block_count as usize {
                let byte_idx = i / 8;
                let bit_idx = i % 8;
                if byte_idx < bitmap.len() && (bitmap[byte_idx] & (1 << bit_idx)) != 0 {
                    used_blocks += 1;
                }
            }
            println!(
                "  Used blocks:      {} ({:.1}%)",
                used_blocks,
                used_blocks as f64 / block_count as f64 * 100.0
            );
        }
        Err(e) => println!("  Error reading block bitmap: {}", e),
    }

    match zfs.read_inode_bitmap() {
        Ok(bitmap) => {
            let mut used_inodes: u32 = 0;
            for i in 0..inode_count as usize {
                let byte_idx = i / 8;
                let bit_idx = i % 8;
                if byte_idx < bitmap.len() && (bitmap[byte_idx] & (1 << bit_idx)) != 0 {
                    used_inodes += 1;
                }
            }
            println!(
                "  Used inodes:      {} ({:.1}%)",
                used_inodes,
                used_inodes as f64 / inode_count as f64 * 100.0
            );
        }
        Err(e) => println!("  Error reading inode bitmap: {}", e),
    }

    // Metadata overhead
    let inode_table_start = zfs.superblock.inode_table_start;
    let inode_bitmap_start = zfs.superblock.inode_bitmap_start;
    let block_bitmap_start = zfs.superblock.block_bitmap_start;
    let data_start = zfs.superblock.data_start;

    println!();
    println!("Metadata:");
    println!("  Boot block:       block 0");
    println!("  Superblock:       block 1");
    println!(
        "  Inode table:      blocks {}-{} ({} blocks)",
        inode_table_start,
        inode_bitmap_start - 1,
        inode_bitmap_start - inode_table_start
    );
    println!(
        "  Inode bitmap:     block {} ({} blocks)",
        inode_bitmap_start,
        block_bitmap_start - inode_bitmap_start
    );
    println!(
        "  Block bitmap:     block {} ({} blocks)",
        block_bitmap_start,
        data_start - block_bitmap_start
    );
    println!(
        "  Data area:        blocks {}-{} ({} blocks)",
        data_start,
        block_count - 1,
        block_count - data_start
    );
}

fn cmd_cat(zfs: &mut ZfsImage, path: &str) {
    let inode = match zfs.resolve_path(path) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("cat: {}: {}", path, e);
            return;
        }
    };

    if inode.type_ != ZFS_TYPE_REGULAR {
        eprintln!("cat: {}: Not a regular file", path);
        return;
    }

    let data = match zfs.read_file_data(&inode) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("cat: {}: {}", path, e);
            return;
        }
    };
    if let Err(e) = std::io::stdout().write_all(&data) {
        eprintln!("cat: {}: {}", path, e);
    }
}

fn cmd_tree(zfs: &mut ZfsImage, path: &str, prefix: &str, is_last: bool, is_root: bool) {
    let inode = match zfs.resolve_path(path) {
        Ok(i) => i,
        Err(e) => {
            println!("{}error: {}", prefix, e);
            return;
        }
    };

    let name = if is_root {
        path.to_string()
    } else {
        path.trim_end_matches('/')
            .rsplit('/')
            .next()
            .unwrap_or(path)
            .to_string()
    };

    if is_root {
        println!("{}", name);
    } else {
        let connector = if is_last { "`-- " } else { "|-- " };
        println!("{}{}{}", prefix, connector, name);
    }

    if inode.type_ != ZFS_TYPE_DIRECTORY {
        return;
    }

    let entries = match zfs.read_dir_entries(&inode) {
        Ok(e) => e,
        Err(_) => return,
    };

    // Filter out . and ..
    let child_entries: Vec<&DirEntry> = entries
        .iter()
        .filter(|e| e.name != "." && e.name != "..")
        .collect();

    for (i, entry) in child_entries.iter().enumerate() {
        let child_is_last = i == child_entries.len() - 1;
        let child_path = if path.ends_with('/') {
            format!("{}{}", path, entry.name)
        } else {
            format!("{}/{}", path, entry.name)
        };

        let child_prefix = if is_root {
            if child_is_last {
                "    ".to_string()
            } else {
                "|   ".to_string()
            }
        } else {
            let new_prefix = if is_last {
                format!("{}    ", prefix)
            } else {
                format!("{}|   ", prefix)
            };
            new_prefix
        };

        cmd_tree(zfs, &child_path, &child_prefix, child_is_last, false);
    }
}

fn cmd_dump(zfs: &mut ZfsImage, block_num: u32) {
    match zfs.read_block(block_num) {
        Ok(buf) => {
            println!("Block {} ({} bytes):", block_num, BLOCK_SIZE);
            println!();

            for row in 0..(BLOCK_SIZE / 16) {
                let offset = row * 16;
                print!("{:08X}  ", offset);

                // Hex
                for col in 0..16 {
                    print!("{:02X} ", buf[offset + col]);
                    if col == 7 {
                        print!(" ");
                    }
                }

                print!(" |");

                // ASCII
                for col in 0..16 {
                    let b = buf[offset + col];
                    if b >= 0x20 && b <= 0x7E {
                        print!("{}", b as char);
                    } else {
                        print!(".");
                    }
                }

                println!("|");
            }
        }
        Err(e) => {
            println!("dump: Cannot read block {}: {}", block_num, e);
        }
    }
}

fn cmd_inode_info(zfs: &mut ZfsImage, inode_num: u32) {
    match zfs.read_inode(inode_num) {
        Ok(inode) => {
            println!("Inode {}", inode_num);
            println!("  ID:               {}", inode.id);
            println!(
                "  Type:             {} ({})",
                inode.type_,
                file_type_str(inode.type_)
            );
            println!(
                "  Mode:             {:o} ({})",
                inode.mode,
                format_mode(inode.mode, inode.type_)
            );
            println!("  Size:             {} bytes", inode.size);
            println!("  UID:              {}", inode.uid);
            println!("  GID:              {}", inode.gid);
            println!("  Links:            {}", inode.nlink);
            println!("  Created:          {}", inode.created);
            println!("  Modified:         {}", inode.modified);
            println!();
            print_block_pointers(zfs, &inode);
            println!();

            if inode.type_ == ZFS_TYPE_DIRECTORY {
                match zfs.read_dir_entries(&inode) {
                    Ok(entries) => {
                        println!("  Directory entries:");
                        for entry in &entries {
                            println!("    inode {:>4}: {}", entry.inode, entry.name);
                        }
                    }
                    Err(e) => {
                        println!("  Error reading directory entries: {}", e);
                    }
                }
            }
        }
        Err(e) => {
            println!("inode: Cannot read inode {}: {}", inode_num, e);
        }
    }
}

fn cmd_mkdir(zfs: &mut ZfsImage, path: &str) {
    let path = path.trim_end_matches('/');
    let (parent_path, name) = match path.rfind('/') {
        None | Some(0) => ("/", path.trim_start_matches('/')),
        Some(idx) => (&path[..idx], &path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("mkdir: invalid path");
        return;
    }

    // Resolve parent directory
    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mkdir: {}: {}", parent_path, e);
            return;
        }
    };

    // Check if name already exists
    match zfs.read_dir_entries(&parent) {
        Ok(entries) => {
            if entries.iter().any(|e| e.name == name) {
                eprintln!("mkdir: '{}': File exists", path);
                return;
            }
        }
        Err(e) => {
            eprintln!("mkdir: {}: {}", parent_path, e);
            return;
        }
    }

    // Allocate inode
    let inode_num = match zfs.alloc_inode() {
        Ok(n) => n,
        Err(e) => {
            eprintln!("mkdir: {}", e);
            return;
        }
    };

    // Allocate a block for the directory
    let block_num = match zfs.alloc_block() {
        Ok(n) => n,
        Err(e) => {
            eprintln!("mkdir: {}", e);
            let _ = zfs.free_inode(inode_num);
            return;
        }
    };

    // Write directory inode
    let inode = Inode {
        id: inode_num,
        type_: ZFS_TYPE_DIRECTORY,
        mode: 0o755 | 0o040000,
        size: BLOCK_SIZE as u32,
        uid: 0,
        gid: 0,
        nlink: 2,
        created: 0,
        modified: 0,
        blocks: {
            let mut b = [0u32; DIRECT_BLOCKS];
            b[0] = block_num;
            b
        },
        single_indirect: 0,
        double_indirect: 0,
        triple_indirect: 0,
    };

    if let Err(e) = zfs.write_inode(&inode) {
        eprintln!("mkdir: {}", e);
        return;
    }

    // Write . and .. entries into the new directory block
    let mut buf = [0u8; BLOCK_SIZE];
    // Entry 0: "."
    buf[0] = b'.';
    buf[MAX_NAME_LEN..MAX_NAME_LEN + 4].copy_from_slice(&inode_num.to_le_bytes());
    // Entry 1: ".."
    buf[DIRENT_SIZE] = b'.';
    buf[DIRENT_SIZE + 1] = b'.';
    buf[DIRENT_SIZE + MAX_NAME_LEN..DIRENT_SIZE + MAX_NAME_LEN + 4]
        .copy_from_slice(&parent.id.to_le_bytes());

    if let Err(e) = zfs.write_block(block_num, &buf) {
        eprintln!("mkdir: {}", e);
        return;
    }

    // Add entry to parent directory
    if let Err(e) = zfs.add_dir_entry(parent.id, name, inode_num) {
        eprintln!("mkdir: {}", e);
        return;
    }

    println!("Created directory: {}", path);
}

fn cmd_touch(zfs: &mut ZfsImage, path: &str) {
    let path = path.trim_end_matches('/');
    let (parent_path, name) = match path.rfind('/') {
        None | Some(0) => ("/", path.trim_start_matches('/')),
        Some(idx) => (&path[..idx], &path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("touch: invalid path");
        return;
    }

    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("touch: {}: {}", parent_path, e);
            return;
        }
    };

    // If file already exists, just return
    match zfs.read_dir_entries(&parent) {
        Ok(entries) => {
            if entries.iter().any(|e| e.name == name) {
                return;
            }
        }
        Err(e) => {
            eprintln!("touch: {}: {}", parent_path, e);
            return;
        }
    }

    let inode_num = match zfs.alloc_inode() {
        Ok(n) => n,
        Err(e) => {
            eprintln!("touch: {}", e);
            return;
        }
    };

    let inode = Inode {
        id: inode_num,
        type_: ZFS_TYPE_REGULAR,
        mode: 0o644,
        size: 0,
        uid: 0,
        gid: 0,
        nlink: 1,
        created: 0,
        modified: 0,
        blocks: [0u32; DIRECT_BLOCKS],
        single_indirect: 0,
        double_indirect: 0,
        triple_indirect: 0,
    };

    if let Err(e) = zfs.write_inode(&inode) {
        eprintln!("touch: {}", e);
        return;
    }

    if let Err(e) = zfs.add_dir_entry(parent.id, name, inode_num) {
        eprintln!("touch: {}", e);
        return;
    }

    println!("Created file: {}", path);
}

fn cmd_write(zfs: &mut ZfsImage, path: &str, content: &str) {
    let path = path.trim_end_matches('/');
    let (parent_path, name) = match path.rfind('/') {
        None | Some(0) => ("/", path.trim_start_matches('/')),
        Some(idx) => (&path[..idx], &path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("write: invalid path");
        return;
    }

    let content_bytes = content.as_bytes();
    if content_bytes.len() > MAX_FILE_SIZE {
        eprintln!(
            "write: file too large ({} bytes, max {} bytes)",
            content_bytes.len(),
            MAX_FILE_SIZE
        );
        return;
    }

    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("write: {}: {}", parent_path, e);
            return;
        }
    };

    // Check if file exists
    let existing_inode_num = match zfs.read_dir_entries(&parent) {
        Ok(entries) => entries.iter().find(|e| e.name == name).map(|e| e.inode),
        Err(e) => {
            eprintln!("write: {}: {}", parent_path, e);
            return;
        }
    };

    if let Some(inode_num) = existing_inode_num {
        let mut inode = match zfs.read_inode(inode_num) {
            Ok(i) => i,
            Err(e) => {
                eprintln!("write: {}", e);
                return;
            }
        };
        if inode.type_ != ZFS_TYPE_REGULAR {
            eprintln!("write: '{}': Not a regular file", path);
            return;
        }
        if let Err(e) = zfs.free_file_blocks(&inode) {
            eprintln!("write: {}", e);
            return;
        }

        ZfsImage::clear_block_pointers(&mut inode);
        if let Err(e) = zfs.write_file_data(&mut inode, content_bytes) {
            let _ = zfs.free_file_blocks(&inode);
            eprintln!("write: {}", e);
            return;
        }
        println!("Wrote {} bytes to {}", content_bytes.len(), path);
        return;
    }

    // Create new file
    let inode_num = match zfs.alloc_inode() {
        Ok(n) => n,
        Err(e) => {
            eprintln!("write: {}", e);
            return;
        }
    };

    let mut inode = Inode {
        id: inode_num,
        type_: ZFS_TYPE_REGULAR,
        mode: 0o644,
        size: 0,
        uid: 0,
        gid: 0,
        nlink: 1,
        created: 0,
        modified: 0,
        blocks: [0u32; DIRECT_BLOCKS],
        single_indirect: 0,
        double_indirect: 0,
        triple_indirect: 0,
    };

    if let Err(e) = zfs.write_file_data(&mut inode, content_bytes) {
        let _ = zfs.free_file_blocks(&inode);
        let _ = zfs.free_inode(inode_num);
        eprintln!("write: {}", e);
        return;
    }

    if let Err(e) = zfs.add_dir_entry(parent.id, name, inode_num) {
        let _ = zfs.free_file_blocks(&inode);
        let _ = zfs.free_inode(inode_num);
        eprintln!("write: {}", e);
        return;
    }

    println!("Wrote {} bytes to {}", content_bytes.len(), path);
}

fn cmd_rm(zfs: &mut ZfsImage, path: &str) {
    let path = path.trim_end_matches('/');
    let (parent_path, name) = match path.rfind('/') {
        None | Some(0) => ("/", path.trim_start_matches('/')),
        Some(idx) => (&path[..idx], &path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("rm: invalid path");
        return;
    }

    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("rm: {}: {}", parent_path, e);
            return;
        }
    };

    // Find the file
    let inode_num = match zfs.read_dir_entries(&parent) {
        Ok(entries) => match entries.iter().find(|e| e.name == name) {
            Some(e) => e.inode,
            None => {
                eprintln!("rm: '{}': No such file or directory", path);
                return;
            }
        },
        Err(e) => {
            eprintln!("rm: {}: {}", parent_path, e);
            return;
        }
    };

    let inode = match zfs.read_inode(inode_num) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("rm: {}", e);
            return;
        }
    };

    if inode.type_ == ZFS_TYPE_DIRECTORY {
        eprintln!("rm: '{}': Is a directory (use rmdir)", path);
        return;
    }

    if let Err(e) = zfs.free_file_blocks(&inode) {
        eprintln!("rm: warning: {}", e);
    }

    // Free inode
    if let Err(e) = zfs.free_inode(inode_num) {
        eprintln!("rm: warning: {}", e);
    }

    // Remove directory entry
    if let Err(e) = zfs.remove_dir_entry(parent.id, name) {
        eprintln!("rm: {}", e);
        return;
    }

    println!("Removed: {}", path);
}

fn cmd_rmdir(zfs: &mut ZfsImage, path: &str) {
    let path = path.trim_end_matches('/');
    let (parent_path, name) = match path.rfind('/') {
        None | Some(0) => ("/", path.trim_start_matches('/')),
        Some(idx) => (&path[..idx], &path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("rmdir: invalid path");
        return;
    }

    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("rmdir: {}: {}", parent_path, e);
            return;
        }
    };

    let inode_num = match zfs.read_dir_entries(&parent) {
        Ok(entries) => match entries.iter().find(|e| e.name == name) {
            Some(e) => e.inode,
            None => {
                eprintln!("rmdir: '{}': No such directory", path);
                return;
            }
        },
        Err(e) => {
            eprintln!("rmdir: {}: {}", parent_path, e);
            return;
        }
    };

    let inode = match zfs.read_inode(inode_num) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("rmdir: {}", e);
            return;
        }
    };

    if inode.type_ != ZFS_TYPE_DIRECTORY {
        eprintln!("rmdir: '{}': Not a directory", path);
        return;
    }

    // Check if directory is empty (only . and .. entries)
    let entries = match zfs.read_dir_entries(&inode) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("rmdir: {}", e);
            return;
        }
    };
    let real_entries: Vec<&DirEntry> = entries
        .iter()
        .filter(|e| e.name != "." && e.name != "..")
        .collect();
    if !real_entries.is_empty() {
        eprintln!(
            "rmdir: '{}': Directory not empty ({} entries)",
            path,
            real_entries.len()
        );
        return;
    }

    if let Err(e) = zfs.free_file_blocks(&inode) {
        eprintln!("rmdir: warning: {}", e);
    }

    // Free inode
    if let Err(e) = zfs.free_inode(inode_num) {
        eprintln!("rmdir: warning: {}", e);
    }

    // Remove directory entry
    if let Err(e) = zfs.remove_dir_entry(parent.id, name) {
        eprintln!("rmdir: {}", e);
        return;
    }

    println!("Removed directory: {}", path);
}

fn cmd_cp(zfs: &mut ZfsImage, host_path: &str, zfs_path: &str) {
    let data = match std::fs::read(host_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("cp: cannot read '{}': {}", host_path, e);
            return;
        }
    };

    if data.len() > MAX_FILE_SIZE {
        eprintln!(
            "cp: file too large ({} bytes, max {} bytes)",
            data.len(),
            MAX_FILE_SIZE
        );
        return;
    }

    let zfs_path = zfs_path.trim_end_matches('/');
    let (parent_path, name) = match zfs_path.rfind('/') {
        None | Some(0) => ("/", zfs_path.trim_start_matches('/')),
        Some(idx) => (&zfs_path[..idx], &zfs_path[idx + 1..]),
    };
    let parent_path = if parent_path.is_empty() {
        "/"
    } else {
        parent_path
    };

    if name.is_empty() {
        eprintln!("cp: invalid target path");
        return;
    }

    let parent = match zfs.resolve_path(parent_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cp: {}: {}", parent_path, e);
            return;
        }
    };

    // Check if file exists - if so, overwrite it
    let existing = match zfs.read_dir_entries(&parent) {
        Ok(entries) => entries.iter().find(|e| e.name == name).map(|e| e.inode),
        Err(e) => {
            eprintln!("cp: {}: {}", parent_path, e);
            return;
        }
    };

    if let Some(inode_num) = existing {
        let mut inode = match zfs.read_inode(inode_num) {
            Ok(i) => i,
            Err(e) => {
                eprintln!("cp: {}", e);
                return;
            }
        };
        if inode.type_ != ZFS_TYPE_REGULAR {
            eprintln!("cp: '{}': Not a regular file", zfs_path);
            return;
        }
        if let Err(e) = zfs.free_file_blocks(&inode) {
            eprintln!("cp: {}", e);
            return;
        }

        ZfsImage::clear_block_pointers(&mut inode);
        if let Err(e) = zfs.write_file_data(&mut inode, &data) {
            let _ = zfs.free_file_blocks(&inode);
            eprintln!("cp: {}", e);
            return;
        }
        println!("Copied {} bytes: {} -> {}", data.len(), host_path, zfs_path);
        return;
    }

    // Create new file
    let inode_num = match zfs.alloc_inode() {
        Ok(n) => n,
        Err(e) => {
            eprintln!("cp: {}", e);
            return;
        }
    };

    let mut inode = Inode {
        id: inode_num,
        type_: ZFS_TYPE_REGULAR,
        mode: 0o755,
        size: 0,
        uid: 0,
        gid: 0,
        nlink: 1,
        created: 0,
        modified: 0,
        blocks: [0u32; DIRECT_BLOCKS],
        single_indirect: 0,
        double_indirect: 0,
        triple_indirect: 0,
    };

    if let Err(e) = zfs.write_file_data(&mut inode, &data) {
        let _ = zfs.free_file_blocks(&inode);
        let _ = zfs.free_inode(inode_num);
        eprintln!("cp: {}", e);
        return;
    }

    if let Err(e) = zfs.add_dir_entry(parent.id, name, inode_num) {
        let _ = zfs.free_file_blocks(&inode);
        let _ = zfs.free_inode(inode_num);
        eprintln!("cp: {}", e);
        return;
    }

    println!("Copied {} bytes: {} -> {}", data.len(), host_path, zfs_path);
}

fn cmd_cpout(zfs: &mut ZfsImage, zfs_path: &str, host_path: &str) {
    let inode = match zfs.resolve_path(zfs_path) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("cpout: {}: {}", zfs_path, e);
            return;
        }
    };

    if inode.type_ != ZFS_TYPE_REGULAR {
        eprintln!("cpout: '{}': Not a regular file", zfs_path);
        return;
    }

    let data = match zfs.read_file_data(&inode) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("cpout: {}", e);
            return;
        }
    };

    match std::fs::write(host_path, &data) {
        Ok(()) => {
            println!("Copied {} bytes: {} -> {}", data.len(), zfs_path, host_path);
        }
        Err(e) => {
            eprintln!("cpout: cannot write '{}': {}", host_path, e);
        }
    }
}

// ============================================================================
// Main
// ============================================================================

fn print_usage() {
    eprintln!("Usage: zfs_cli <disk_image> <command> [args...]");
    eprintln!();
    eprintln!("Read commands:");
    eprintln!("  info                  Show filesystem information");
    eprintln!("  ls [path]             List directory contents (default: /)");
    eprintln!("  stat <path>           Show file/directory details");
    eprintln!("  usage                 Show disk usage statistics");
    eprintln!("  cat <path>            Dump file contents to stdout");
    eprintln!("  tree [path]           Show directory tree (default: /)");
    eprintln!("  dump <block>          Dump raw block data (hex + ascii)");
    eprintln!("  inode <num>           Show raw inode data");
    eprintln!();
    eprintln!("Write commands:");
    eprintln!("  mkdir <path>          Create a directory");
    eprintln!("  touch <path>          Create an empty file");
    eprintln!("  write <path> <text>   Write text to a file (overwrite)");
    eprintln!("  rm <path>             Remove a file");
    eprintln!("  rmdir <path>          Remove an empty directory");
    eprintln!("  cp <host> <zfs>       Copy host file into ZFS image");
    eprintln!("  cpout <zfs> <host>    Copy ZFS file to host filesystem");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  zfs_cli disk.img info");
    eprintln!("  zfs_cli disk.img ls /");
    eprintln!("  zfs_cli disk.img mkdir /mydir");
    eprintln!("  zfs_cli disk.img write /mydir/hello.txt 'Hello World!'");
    eprintln!("  zfs_cli disk.img cat /mydir/hello.txt");
    eprintln!("  zfs_cli disk.img rm /mydir/hello.txt");
    eprintln!("  zfs_cli disk.img cp /etc/passwd /etc/passwd");
    eprintln!("  zfs_cli disk.img cpout /hello.txt /tmp/hello.txt");
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 3 {
        print_usage();
        std::process::exit(1);
    }

    let disk_path = &args[1];
    let command = &args[2];

    let mut zfs = match ZfsImage::open(disk_path) {
        Ok(z) => z,
        Err(e) => {
            eprintln!("zfs_cli: {}", e);
            std::process::exit(1);
        }
    };

    match command.as_str() {
        "info" => cmd_info(&mut zfs),
        "ls" => {
            let path = args.get(3).map(|s| s.as_str()).unwrap_or("/");
            cmd_ls(&mut zfs, path);
        }
        "stat" => {
            if args.len() < 4 {
                eprintln!("stat: missing path operand");
                eprintln!("Usage: zfs_cli <disk> stat <path>");
                std::process::exit(1);
            }
            cmd_stat(&mut zfs, &args[3]);
        }
        "usage" => cmd_usage(&mut zfs),
        "cat" => {
            if args.len() < 4 {
                eprintln!("cat: missing path operand");
                eprintln!("Usage: zfs_cli <disk> cat <path>");
                std::process::exit(1);
            }
            cmd_cat(&mut zfs, &args[3]);
        }
        "tree" => {
            let path = args.get(3).map(|s| s.as_str()).unwrap_or("/");
            cmd_tree(&mut zfs, path, "", true, true);
        }
        "dump" => {
            if args.len() < 4 {
                eprintln!("dump: missing block number");
                eprintln!("Usage: zfs_cli <disk> dump <block_num>");
                std::process::exit(1);
            }
            match args[3].parse::<u32>() {
                Ok(block_num) => cmd_dump(&mut zfs, block_num),
                Err(_) => {
                    eprintln!("dump: invalid block number: {}", args[3]);
                    std::process::exit(1);
                }
            }
        }
        "inode" => {
            if args.len() < 4 {
                eprintln!("inode: missing inode number");
                eprintln!("Usage: zfs_cli <disk> inode <inode_num>");
                std::process::exit(1);
            }
            match args[3].parse::<u32>() {
                Ok(inode_num) => cmd_inode_info(&mut zfs, inode_num),
                Err(_) => {
                    eprintln!("inode: invalid inode number: {}", args[3]);
                    std::process::exit(1);
                }
            }
        }
        "help" | "--help" | "-h" => print_usage(),
        "mkdir" => {
            if args.len() < 4 {
                eprintln!("mkdir: missing path operand");
                eprintln!("Usage: zfs_cli <disk> mkdir <path>");
                std::process::exit(1);
            }
            cmd_mkdir(&mut zfs, &args[3]);
        }
        "touch" => {
            if args.len() < 4 {
                eprintln!("touch: missing path operand");
                eprintln!("Usage: zfs_cli <disk> touch <path>");
                std::process::exit(1);
            }
            cmd_touch(&mut zfs, &args[3]);
        }
        "write" => {
            if args.len() < 5 {
                eprintln!("write: missing operand");
                eprintln!("Usage: zfs_cli <disk> write <path> <content>");
                std::process::exit(1);
            }
            cmd_write(&mut zfs, &args[3], &args[4]);
        }
        "rm" => {
            if args.len() < 4 {
                eprintln!("rm: missing path operand");
                eprintln!("Usage: zfs_cli <disk> rm <path>");
                std::process::exit(1);
            }
            cmd_rm(&mut zfs, &args[3]);
        }
        "rmdir" => {
            if args.len() < 4 {
                eprintln!("rmdir: missing path operand");
                eprintln!("Usage: zfs_cli <disk> rmdir <path>");
                std::process::exit(1);
            }
            cmd_rmdir(&mut zfs, &args[3]);
        }
        "cp" => {
            if args.len() < 5 {
                eprintln!("cp: missing operand");
                eprintln!("Usage: zfs_cli <disk> cp <host_path> <zfs_path>");
                std::process::exit(1);
            }
            cmd_cp(&mut zfs, &args[3], &args[4]);
        }
        "cpout" => {
            if args.len() < 5 {
                eprintln!("cpout: missing operand");
                eprintln!("Usage: zfs_cli <disk> cpout <zfs_path> <host_path>");
                std::process::exit(1);
            }
            cmd_cpout(&mut zfs, &args[3], &args[4]);
        }
        _ => {
            eprintln!("zfs_cli: unknown command: {}", command);
            eprintln!("Run 'zfs_cli --help' for usage information");
            std::process::exit(1);
        }
    }
}
