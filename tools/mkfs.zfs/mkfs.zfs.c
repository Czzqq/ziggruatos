/*
 * mkfs.zfs - ZFS (Ziggurat File System) Disk Image Creator
 *
 * Creates a formatted ZFS disk image from user space.
 *
 * Usage: ./mkfs.zfs <disk_image_path> [size_in_MB]
 * Default size: 10MB
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// ZFS on-disk structures (must match zfs_disk.zig)
#define ZFS_MAGIC 0x5A495353554D4F21ull  // "ZIGSUM!"
#define ZFS_VERSION 2
#define BLOCK_SIZE 4096
#define MAX_NAME_LEN 24
#define DIRECT_BLOCKS 12

// File types
#define ZFS_TYPE_FREE 0
#define ZFS_TYPE_REGULAR 1
#define ZFS_TYPE_DIRECTORY 2

// Superblock structure (512 bytes) - match Zig layout
// Note: Must match zfs_disk.zig SuperBlock exactly
typedef struct {
    uint64_t magic;
    uint32_t version;
    uint32_t block_size;
    uint32_t block_count;
    uint32_t inode_count;
    uint32_t free_blocks;
    uint32_t free_inodes;
    uint32_t root_inode;
    uint64_t creation_time;  // Natural alignment: after root_inode at offset 36, 
                             // aligned to 8-byte boundary at offset 40 in Zig
    uint32_t block_bitmap_start;
    uint32_t inode_bitmap_start;
    uint32_t inode_table_start;  // Should be at offset 52 in Zig
    uint32_t data_start;
    uint8_t reserved[448];
} SuperBlock;

// Inode structure (128 bytes) - must match zfs_disk.zig layout
// Zig extern struct layout: natural alignment
// Total: 4+1+1(pad)+2+4+2+2+2+4(pad)+8+8+48+12+28 = 128 bytes
typedef struct {
    uint32_t id;          // offset 0
    uint8_t type_;        // offset 4
    uint8_t _pad1;        // offset 5 (padding for mode alignment)
    uint16_t mode;        // offset 6
    uint32_t size;        // offset 8
    uint16_t uid;         // offset 12
    uint16_t gid;         // offset 14
    uint16_t nlink;       // offset 16
    uint8_t _pad2[6];     // offset 18-23 (padding for created alignment)
    uint64_t created;     // offset 24
    uint64_t modified;    // offset 32
    uint32_t blocks[DIRECT_BLOCKS];  // offset 40
    uint32_t single_indirect;        // offset 88
    uint32_t double_indirect;        // offset 92
    uint32_t triple_indirect;        // offset 96
    uint32_t reserved[7];            // offset 100-127
} Inode;

// Directory entry structure (32 bytes)
typedef struct {
    char name[MAX_NAME_LEN];
    uint32_t inode;
    uint32_t _padding;
} __attribute__((packed)) DirEntry;

// Calculate filesystem layout
static void calculate_layout(uint64_t disk_size, uint32_t *block_count, uint32_t *inode_count) {
    *block_count = disk_size / BLOCK_SIZE;
    // 1 inode per 16KB
    *inode_count = (disk_size / (16 * 1024)) + 1;
    if (*inode_count < 2) *inode_count = 2; // At least root + 1
}

// Initialize superblock
static void init_superblock(SuperBlock *sb, uint32_t block_count, uint32_t inode_count) {
    memset(sb, 0, sizeof(SuperBlock));
    sb->magic = ZFS_MAGIC;
    sb->version = ZFS_VERSION;
    sb->block_size = BLOCK_SIZE;
    sb->block_count = block_count;
    sb->inode_count = inode_count;

    // Calculate layout
    uint32_t inode_table_blocks = (inode_count * sizeof(Inode) + BLOCK_SIZE - 1) / BLOCK_SIZE;
    uint32_t inode_bitmap_blocks = (inode_count + 7) / 8 / BLOCK_SIZE;
    if (inode_bitmap_blocks < 1) inode_bitmap_blocks = 1;
    uint32_t block_bitmap_blocks = (block_count + 7) / 8 / BLOCK_SIZE;
    if (block_bitmap_blocks < 1) block_bitmap_blocks = 1;

    sb->inode_table_start = 2;  // After boot block (0) and superblock (1)
    sb->inode_bitmap_start = sb->inode_table_start + inode_table_blocks;
    sb->block_bitmap_start = sb->inode_bitmap_start + inode_bitmap_blocks;
    sb->data_start = sb->block_bitmap_start + block_bitmap_blocks;

    sb->free_blocks = block_count - sb->data_start;
    sb->free_inodes = inode_count - 1;  // Root inode already allocated
    sb->root_inode = 0;
    sb->creation_time = 0;  // Could use time()
}

// Create a zeroed disk image
static int create_disk_image(const char *path, uint64_t size) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "Error: Cannot create %s: %s\n", path, strerror(errno));
        return -1;
    }

    // Write zeros
    uint8_t zero_block[BLOCK_SIZE];
    memset(zero_block, 0, BLOCK_SIZE);

    uint64_t written = 0;
    while (written < size) {
        ssize_t n = write(fd, zero_block, BLOCK_SIZE);
        if (n < 0) {
            fprintf(stderr, "Error: Write failed: %s\n", strerror(errno));
            close(fd);
            return -1;
        }
        written += n;
    }

    close(fd);
    return 0;
}

// Write superblock to disk
static int write_superblock(int fd, const SuperBlock *sb) {
    if (lseek(fd, BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to superblock: %s\n", strerror(errno));
        return -1;
    }

    if (write(fd, sb, sizeof(SuperBlock)) != sizeof(SuperBlock)) {
        fprintf(stderr, "Error: Cannot write superblock: %s\n", strerror(errno));
        return -1;
    }

    return 0;
}

// Write inode bitmap
static int write_inode_bitmap(int fd, const SuperBlock *sb) {
    uint8_t *bitmap = calloc(BLOCK_SIZE, 1);
    if (!bitmap) {
        fprintf(stderr, "Error: Out of memory\n");
        return -1;
    }

    // Mark root inode (inode 0) as used
    bitmap[0] = 0x01;

    if (lseek(fd, (off_t)sb->inode_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to inode bitmap: %s\n", strerror(errno));
        free(bitmap);
        return -1;
    }

    if (write(fd, bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write inode bitmap: %s\n", strerror(errno));
        free(bitmap);
        return -1;
    }

    free(bitmap);
    return 0;
}

// Write block bitmap
static int write_block_bitmap(int fd, const SuperBlock *sb) {
    uint8_t *bitmap = calloc(BLOCK_SIZE, 1);
    if (!bitmap) {
        fprintf(stderr, "Error: Out of memory\n");
        return -1;
    }

    // Mark metadata blocks as used (0 through data_start - 1)
    for (uint32_t i = 0; i < sb->data_start; i++) {
        bitmap[i / 8] |= (1 << (i % 8));
    }

    if (lseek(fd, (off_t)sb->block_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to block bitmap: %s\n", strerror(errno));
        free(bitmap);
        return -1;
    }

    if (write(fd, bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write block bitmap: %s\n", strerror(errno));
        free(bitmap);
        return -1;
    }

    free(bitmap);
    return 0;
}

// Write root inode
static int write_root_inode(int fd, SuperBlock *sb) {
    Inode root;
    memset(&root, 0, sizeof(Inode));
    root.id = 0;
    root.type_ = ZFS_TYPE_DIRECTORY;
    root.mode = 0755 | 040000;  // S_IFDIR
    root.size = BLOCK_SIZE;
    root.uid = 0;
    root.gid = 0;
    root.nlink = 2;
    root.created = 0;
    root.modified = 0;
    root.blocks[0] = sb->data_start;  // First data block
    for (int i = 1; i < DIRECT_BLOCKS; i++) {
        root.blocks[i] = 0;
    }
    sb->free_blocks--;

    if (lseek(fd, (off_t)sb->inode_table_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to inode table: %s\n", strerror(errno));
        return -1;
    }

    if (write(fd, &root, sizeof(Inode)) != sizeof(Inode)) {
        fprintf(stderr, "Error: Cannot write root inode: %s\n", strerror(errno));
        return -1;
    }

    return 0;
}

// Write root directory entries
static int write_root_dir(int fd, const SuperBlock *sb) {
    DirEntry entries[BLOCK_SIZE / sizeof(DirEntry)];
    memset(entries, 0, sizeof(entries));

    // Entry 0: .
    strcpy(entries[0].name, ".");
    entries[0].inode = 0;
    entries[0]._padding = 0;

    // Entry 1: ..
    strcpy(entries[1].name, "..");
    entries[1].inode = 0;
    entries[1]._padding = 0;

    if (lseek(fd, (off_t)sb->data_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to root directory: %s\n", strerror(errno));
        return -1;
    }

    if (write(fd, entries, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write root directory: %s\n", strerror(errno));
        return -1;
    }

    return 0;
}

// Create some sample files in the filesystem
static int create_sample_files(int fd, SuperBlock *sb) {
    // Create a sample file "hello.txt"
    Inode hello_inode;
    memset(&hello_inode, 0, sizeof(Inode));
    hello_inode.id = 1;  // Inode 1
    hello_inode.type_ = ZFS_TYPE_REGULAR;
    hello_inode.mode = 0644;
    hello_inode.size = 14;  // "Hello, ZFS!\n"
    hello_inode.blocks[0] = sb->data_start + 1;  // Second data block
    hello_inode.nlink = 1;
    sb->free_blocks--;
    sb->free_inodes--;

    // Write inode
    if (lseek(fd, (off_t)sb->inode_table_start * BLOCK_SIZE + sizeof(Inode), SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to inode table\n");
        return -1;
    }

    if (write(fd, &hello_inode, sizeof(Inode)) != sizeof(Inode)) {
        fprintf(stderr, "Error: Cannot write hello inode\n");
        return -1;
    }

    // Mark inode 1 as used in bitmap
    if (lseek(fd, (off_t)sb->inode_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to inode bitmap\n");
        return -1;
    }

    uint8_t inode_bitmap[BLOCK_SIZE];
    if (read(fd, inode_bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot read inode bitmap\n");
        return -1;
    }

    inode_bitmap[0] |= 0x03;  // Mark inode 0 and 1 as used

    if (lseek(fd, (off_t)sb->inode_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to inode bitmap\n");
        return -1;
    }

    if (write(fd, inode_bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write inode bitmap\n");
        return -1;
    }

    // Write file content
    if (lseek(fd, (off_t)(sb->data_start + 1) * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to data block\n");
        return -1;
    }

    const char *content = "Hello, ZFS!\n";
    if (write(fd, content, strlen(content)) != (ssize_t)strlen(content)) {
        fprintf(stderr, "Error: Cannot write file content\n");
        return -1;
    }

    // Mark data block as used in block bitmap
    if (lseek(fd, (off_t)sb->block_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to block bitmap\n");
        return -1;
    }

    uint8_t block_bitmap[BLOCK_SIZE];
    if (read(fd, block_bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot read block bitmap\n");
        return -1;
    }

    // Mark data_start and data_start+1 as used
    block_bitmap[sb->data_start / 8] |= (1 << (sb->data_start % 8));
    block_bitmap[(sb->data_start + 1) / 8] |= (1 << ((sb->data_start + 1) % 8));

    if (lseek(fd, (off_t)sb->block_bitmap_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to block bitmap\n");
        return -1;
    }

    if (write(fd, block_bitmap, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write block bitmap\n");
        return -1;
    }

    // Add directory entry for hello.txt
    if (lseek(fd, (off_t)sb->data_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to root directory\n");
        return -1;
    }

    DirEntry entries[BLOCK_SIZE / sizeof(DirEntry)];
    if (read(fd, entries, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot read root directory\n");
        return -1;
    }

    // Entry 2: hello.txt
    strcpy(entries[2].name, "hello.txt");
    entries[2].inode = 1;
    entries[2]._padding = 0;

    if (lseek(fd, (off_t)sb->data_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to root directory\n");
        return -1;
    }

    if (write(fd, entries, BLOCK_SIZE) != BLOCK_SIZE) {
        fprintf(stderr, "Error: Cannot write root directory\n");
        return -1;
    }

    // Update root directory inode to reflect new entry
    Inode root_inode;
    if (lseek(fd, (off_t)sb->inode_table_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to root inode\n");
        return -1;
    }

    if (read(fd, &root_inode, sizeof(Inode)) != sizeof(Inode)) {
        fprintf(stderr, "Error: Cannot read root inode\n");
        return -1;
    }

    root_inode.nlink = 3;  // ., .., and the hello.txt entry

    if (lseek(fd, (off_t)sb->inode_table_start * BLOCK_SIZE, SEEK_SET) < 0) {
        fprintf(stderr, "Error: Cannot seek to root inode\n");
        return -1;
    }

    if (write(fd, &root_inode, sizeof(Inode)) != sizeof(Inode)) {
        fprintf(stderr, "Error: Cannot write root inode\n");
        return -1;
    }

    return 0;
}

int main(int argc, char *argv[]) {
    const char *disk_path = NULL;
    uint64_t size_mb = 10;  // Default 10MB

    // Parse arguments
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <disk_image_path> [size_in_MB]\n", argv[0]);
        fprintf(stderr, "  Default size: 10MB\n");
        return 1;
    }

    disk_path = argv[1];

    if (argc >= 3) {
        size_mb = atoi(argv[2]);
        if (size_mb == 0 || size_mb > 1024) {
            fprintf(stderr, "Error: Invalid size. Must be between 1 and 1024 MB\n");
            return 1;
        }
    }

    uint64_t size_bytes = size_mb * 1024 * 1024;
    printf("Creating ZFS disk image: %s (%lu MB = %lu bytes)\n",
           disk_path, size_mb, size_bytes);

    // Calculate layout
    uint32_t block_count, inode_count;
    calculate_layout(size_bytes, &block_count, &inode_count);
    printf("  Block size: %d bytes\n", BLOCK_SIZE);
    printf("  Total blocks: %u\n", block_count);
    printf("  Total inodes: %u\n", inode_count);

    // Create disk image
    if (create_disk_image(disk_path, size_bytes) < 0) {
        return 1;
    }

    // Open for writing
    int fd = open(disk_path, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "Error: Cannot open %s for writing: %s\n",
                disk_path, strerror(errno));
        return 1;
    }

    // Initialize superblock
    SuperBlock sb;
    init_superblock(&sb, block_count, inode_count);

    printf("  Block bitmap start: block %u\n", sb.block_bitmap_start);
    printf("  Inode bitmap start: block %u\n", sb.inode_bitmap_start);
    printf("  Inode table start: block %u\n", sb.inode_table_start);
    printf("  Data start: block %u\n", sb.data_start);
    printf("  Free blocks: %u\n", sb.free_blocks);
    printf("  Free inodes: %u\n", sb.free_inodes);

    // Write filesystem structures
    printf("\nWriting filesystem structures...\n");

    if (write_superblock(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  Superblock written\n");

    if (write_inode_bitmap(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  Inode bitmap written\n");

    if (write_block_bitmap(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  Block bitmap written\n");

    if (write_root_inode(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  Root inode written\n");

    if (write_root_dir(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  Root directory initialized\n");

    // Create sample files
    printf("\nCreating sample files...\n");
    if (create_sample_files(fd, &sb) < 0) {
        close(fd);
        return 1;
    }
    printf("  hello.txt created\n");

    if (write_superblock(fd, &sb) < 0) {
        close(fd);
        return 1;
    }

    close(fd);

    printf("\nZFS disk image created successfully!\n");
    printf("\nYou can now run ZigguratOS with:\n");
    printf("  qemu-system-riscv64 -drive file=%s,format=raw,if=virtio ...\n", disk_path);

    return 0;
}
