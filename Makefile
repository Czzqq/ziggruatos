# Thin wrapper around the Zig build system.
#
# Compilation and configuration live in build.zig (see `zig build --help`).
# Interactive tools (QEMU, GDB) are launched directly from this Makefile with
# `exec` instead of through `zig build`, so terminal signals such as Ctrl-C
# reach the tool itself -- in particular Ctrl-C inside GDB interrupts the
# remote target instead of tearing down GDB.

.DEFAULT_GOAL := all

.PHONY: all clean initramfs kernel user run debug gdb disk config mkfs duos duos-fip duos-smallcore

V ?= 0
ZIG ?= zig
GDB_TOOL ?= gdb
QEMU ?= qemu-system-riscv64
GDB_PORT ?= 1235

# Build configuration, forwarded to `zig build -D...`
SBI ?= opensbi
PLATFORM ?= virt
FS ?= zfs
ZFS_DISK_SIZE ?= 10
COPY_TO_ZFS ?= true

# Milk-V DuoS packaging uses an existing SDK FIP and does not rebuild the SDK.
DUO_SDK ?=
DUO_BASE_FIP ?=
DUO_OUT_DIR ?= zig-out/duos

ZIG_BUILD_FLAGS := \
	-Dplatform=$(PLATFORM) \
	-Dfs=$(FS) \
	-Dzfs-disk-mb=$(ZFS_DISK_SIZE) \
	-Dcopy-to-zfs=$(COPY_TO_ZFS)

ifeq ($(V),1)
	ZIG_BUILD_FLAGS += -freference-trace=11
endif

BUILD_KERNEL_DIR := zig-out/bin
BUILD_INITFS_DIR := zig-out/initramfs
OS_TARGET := zigguratOS
KERNEL_BIN := $(BUILD_KERNEL_DIR)/$(OS_TARGET).bin
KERNEL_ELF := $(BUILD_KERNEL_DIR)/$(OS_TARGET)
INITRAMFS ?= initramfs.cpio

BOOTLOADER_PATH := sbi-fireware
ifeq ($(SBI),rustsbi)
  BOOTLOADER_TARGET := $(BOOTLOADER_PATH)/rustsbi-qemu.bin
else ifeq ($(SBI),opensbi)
  BOOTLOADER_TARGET := $(BOOTLOADER_PATH)/fw_payload.bin
else ifeq ($(SBI),custom)
  BOOTLOADER_TARGET := $(BOOTLOADER_PATH)/bootloader
else ifeq ($(SBI),none)
  BOOTLOADER_TARGET :=
else
  $(error "invalid SBI type: $(SBI). Valid options are: rustsbi, opensbi, custom, none")
endif

###############
## build     ##
###############

all:
	@echo " Building ZigguratOS (platform: $(PLATFORM), fs: $(FS))..."
	@$(ZIG) build $(ZIG_BUILD_FLAGS)

kernel:
	@$(ZIG) build kernel $(ZIG_BUILD_FLAGS)

duos:
	@echo " Building ZigguratOS for Milk-V DuoS (tmpfs root)..."
	@$(ZIG) build kernel -Dplatform=duos -Dfs=tmpfs

duos-smallcore:
	@$(ZIG) build kernel -Dplatform=duos-smallcore -Dmmu=off -Dfs=tmpfs -Doptimize=ReleaseSmall

duos-fip: duos
	@test -n "$(DUO_SDK)" || (echo " DUO_SDK is required, e.g. DUO_SDK=/path/to/duo-buildroot-sdk-v2" >&2; exit 1)
	@test -n "$(DUO_BASE_FIP)" || (echo " DUO_BASE_FIP is required, e.g. DUO_BASE_FIP=/path/to/flash/rom/fip.bin" >&2; exit 1)
	@python3 tools/pack_duos_fip.py \
		--sdk "$(DUO_SDK)" \
		--base-fip "$(DUO_BASE_FIP)" \
		--kernel zig-out/bin/$(OS_TARGET).bin \
		--output-dir "$(DUO_OUT_DIR)"

user:
	@$(ZIG) build user $(ZIG_BUILD_FLAGS)

initramfs:
	@$(ZIG) build initramfs $(ZIG_BUILD_FLAGS)

mkfs:
	@$(ZIG) build mkfs

disk:
	@$(ZIG) build disk $(ZIG_BUILD_FLAGS)

config:
	@$(ZIG) build config $(ZIG_BUILD_FLAGS)

clean:
	@$(ZIG) build clean

###################
## run / debug   ##
###################

QEMU_FLAGS += -nographic -machine virt -m 128M \
	-device loader,file=$(BUILD_INITFS_DIR)/$(INITRAMFS),addr=0x82300000 \
	-smp cpus=2

ifeq ($(FS),zfs)
  QEMU_FLAGS += -drive id=disk,file=disk.img,format=raw,if=none \
	-device virtio-blk-device,drive=disk
endif

ifeq ($(SBI),none)
  QEMU_BIOS = -device loader,file=$(KERNEL_BIN),addr=0x80200000
else
  QEMU_BIOS = -bios $(BOOTLOADER_TARGET) \
	-device loader,file=$(KERNEL_BIN),addr=0x80200000
endif

run: all
ifeq ($(FS),zfs)
	@if [ ! -f disk.img ]; then \
		echo " disk.img not found, creating..."; \
		$(ZIG) build disk $(ZIG_BUILD_FLAGS); \
	fi
endif
	@exec $(QEMU) $(QEMU_FLAGS) $(QEMU_BIOS) -kernel $(KERNEL_BIN)

debug: all
ifeq ($(FS),zfs)
	@if [ ! -f disk.img ]; then \
		echo " disk.img not found, creating..."; \
		$(ZIG) build disk $(ZIG_BUILD_FLAGS); \
	fi
endif
	@exec $(QEMU) $(QEMU_FLAGS) $(QEMU_BIOS) -kernel $(KERNEL_BIN) \
		-gdb tcp::$(GDB_PORT) -S

# Attach GDB to `make debug`. Runs GDB directly (not under `zig build`) so
# Ctrl-C is handled by GDB as "interrupt the target", not as a shutdown signal.
gdb:
	@exec $(GDB_TOOL) \
		-ex 'file $(KERNEL_ELF)' \
		-ex 'set arch riscv:rv64' \
		-ex 'target remote localhost:$(GDB_PORT)'
