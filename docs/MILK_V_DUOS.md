# Milk-V DuoS RISC-V S-mode Port

ZigguratOS runs as an S-mode payload on the Milk-V DuoS (SG2000/CV181x).
The RISC-V boot path uses the SDK FSBL and OpenSBI in M-mode. ZigguratOS
replaces only the FIP `LOADER_2ND` entry and boots to its embedded initramfs
shell.

The current scope does not require U-Boot. OpenSBI already performs the
M-mode to S-mode transition and the FSBL supplies a usable FDT. Adding U-Boot
would introduce another S-mode payload, load-address handoff, command
environment, and device-tree ownership without helping the shell-only target.
U-Boot becomes useful later if ZigguratOS must select between multiple images,
load from eMMC or SD through a boot menu, or rely on U-Boot's device setup.

## Boot chain

```text
BootROM
  -> SDK FSBL
  -> SDK OpenSBI (M-mode, preserved byte-for-byte)
  -> ZigguratOS at 0x80200000 (S-mode)
  -> embedded initramfs -> /init -> shell
```

The FSBL loads the monitor first and then writes `LOADER_2ND` to
`0x80200000`. The SDK OpenSBI reports `Domain0 Next Mode: S-mode` and passes
the FDT address in `Domain0 Next Arg1` (`0x80080000` in the tested image).
ZigguratOS uses the same `0x80200000` link address.

Do not replace the monitor with an OpenSBI `FW_PAYLOAD` image. A payload placed
at the normal `FW_PAYLOAD_OFFSET` would overlap the FSBL's separate
`LOADER_2ND` transfer. The packaging flow deliberately keeps the SDK monitor
and replaces only `LOADER_2ND`.

## DuoS UART

The RISC-V DTS describes UART0 as a Synopsys DesignWare APB UART, not as a
plain NS16550:

```text
compatible        snps,dw-apb-uart
base              0x04140000
clock             25 MHz
register shift    2 (32-bit MMIO stride)
PLIC interrupt    44, level high
console           115200 8N1
```

The source of these values is:

```text
build/boards/default/dts/cv181x_riscv/cv181x_base_riscv.dtsi
```

`src/kernel/drivers/dw_apb_uart.zig` implements this device separately from
the NS16550 driver. It supports the DesignWare `reg-shift=2` register bank,
32-bit MMIO registers, UART Component Version detection, the fractional
divisor register at `0xc0`, and 115200 8N1 operation from a 25 MHz clock.

IRQ 30 from the older FreeRTOS configuration is not the Linux/OpenSBI PLIC
mapping. The current RISC-V DTS mapping is IRQ 44. OpenSBI exposes context 1
for the S-mode hart, which is what `board/duos/platform.zig` selects.

The console converts `LF` output to `CRLF`; physical output should be checked
on the current image.

## C906 Sv39 page-table attributes

The T-HEAD C906 uses bits 60-63 of a leaf PTE for cache and ordering
attributes. These are in addition to the standard RISC-V PTE bits:

```text
bit 60  SHARE
bit 61  BUF
bit 62  CACHE
bit 63  SO
```

The SDK Linux definitions in
`linux_5.10/arch/riscv/include/asm/pgtable-bits.h` use:

```text
normal kernel memory: A | D | G | SHARE | BUF | CACHE
MMIO / ioremap:       A | D | G | SHARE | SO
page-table links:     V only
```

The port must therefore keep all 64 PTE bits. Truncating permissions to the low
10 bits loses the C906 memory attributes and can stop the boot immediately
after `PMM Init`, when `satp` is first enabled. `board/duos/config.zig` enables
`thead_pte_extensions`; other platforms retain ordinary Sv39 flags plus
`A | D`.

The initial kernel mapping uses Sv39 2 MiB megapages for aligned regions. This
keeps the approximately 512 MiB identity mapping from allocating more than
126,000 level-0 page tables. Unaligned boundaries, UART MMIO, and other small
mappings still use 4 KiB pages.

With `board/duos/config.zig:boot_trace` enabled, the paging handoff includes
the detailed `Page table:` messages below. The current default is false, so
those detailed lines are normally absent. `Activating Sv39 paging...`,
`Sv39 paging active.` and `Memory system initialized successfully.` are
regular output and remain available with tracing disabled.

Expected output with tracing enabled:

```text
Page table: root allocated at 0x...
Page table: root initialized
Page table: UART mapped
Page table: PLIC mapped
Page table: kernel text mapped
Page table: kernel data mapped
Page table: trampoline mapped
Page table: construction complete
Activating Sv39 paging...
Sv39 paging active.
Memory system initialized successfully.
```

Use the detailed `Page table:` rules only when boot tracing is enabled. With
the default configuration, diagnose progress using the three regular messages
instead; an absent detailed line alone does not indicate a failure.

With tracing enabled, the diagnostic sequence is:

- No `Page table: root allocated`: inspect the first page allocation after
  `PMM Init`.
- A stop between two `Page table:` messages: inspect the mapping named by the
  next missing message.
- Construction complete but no `Activating Sv39 paging...`: the failure is
  between page-table construction and the `satp` write.
- `Activating` but no `Sv39 paging active`: suspect the page table, PTE
  attributes, `satp`, or TLB transition.
- `Sv39 paging active` but no `Memory system initialized successfully`: paging
  completed, so investigate the next trap or allocator initialization step.

## Build and package

The SDK does not need to be rebuilt. The packaging target reads an existing
FIP, invokes the SDK `fiptool.py` to replace `LOADER_2ND`, preserves the
OpenSBI monitor, and verifies the compressed payload after packaging.

```bash
make duos

make duos-fip \
  DUO_SDK=/path/to/duo-buildroot-sdk-v2 \
  DUO_BASE_FIP=/path/to/duo-flash/rom/fip.bin
```

If Zig reports `manifest_create ReadOnlyFileSystem`, point both caches at
writable directories:

```bash
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-local-cache" \
make duos-fip \
  DUO_SDK=/path/to/duo-buildroot-sdk-v2 \
  DUO_BASE_FIP=/path/to/duo-flash/rom/fip.bin
```

Use an unmodified SDK FIP as `DUO_BASE_FIP`. Do not use the stale ZIP inside
`/path/to/duo-flash/rom`.

Artifacts:

```text
zig-out/bin/zigguratOS.bin       raw S-mode kernel payload
zig-out/duos/loader-2nd.bin     loader header plus kernel
zig-out/duos/fip.bin            FIP for USB test and eMMC slot packaging
zig-out/duos/fip-primary-1m.img one eMMC boot slot
zig-out/duos/Boot.bin           two identical 1 MiB eMMC boot slots
zig-out/duos/fip.sha256         FIP checksum
zig-out/duos/Boot.bin.sha256    boot image checksum
```

Artifact sizes and hashes depend on the current build. The packer enforces
the payload boundary and 1 MiB FIP slot limit; use generated checksums.

Check the generated checksums with:

```bash
cd zig-out/duos
sha256sum -c fip.sha256
sha256sum -c Boot.bin.sha256
```

Verify that `Boot.bin` contains the FIP in each of its two 1 MiB slots:

```bash
cd zig-out/duos
cmp -n "$(stat -c %s fip.bin)" Boot.bin fip.bin
cmp \
  <(dd if=Boot.bin bs=1M count=1 status=none) \
  <(dd if=Boot.bin bs=1M skip=1 count=1 status=none)
```

Both `cmp` commands must exit successfully. The examples use Bash process
substitution and GNU stat; substitute local paths before running.

## USB FIP test

`usb_dl -s linux -c 181x` remains usable to transfer the custom FIP, but the
normal command is an SDK update flow, not a standalone RAM-boot command. The
host first transfers `fip.bin` so the BootROM/FSBL can start a second stage,
then continues with `CVI_USB_PROGRAM` and the files listed by the SDK update
metadata.

That second stage is now ZigguratOS rather than the SDK update runtime.
ZigguratOS has no USB device driver, so it starts from RAM but cannot service
the host's remaining update requests. The host eventually remains at:

```text
Waiting for USB device connection
```

This is expected for the custom FIP and does not mean that `usb_dl` is broken
or that `mmcblk0boot0` was written. Stop the host-side command after UART has
confirmed the ZigguratOS boot. Power-cycling the board returns to the
previously installed Linux image.

Do not use `usb_dl -b` as a direct permanent-install path for this FIP. That
mode first sends `fip.bin`, then sends the SDK `ramboot.itb` to the address
expected by the SDK U-Boot update runtime. Replacing that runtime with
ZigguratOS removes the USB programming service needed for the second phase.

Prepare a separate staging directory and update only its FIP:

```bash
cd /path/to/duo-flash
test -e rom-ziggurat-duos || cp -a rom rom-ziggurat-duos
cp /path/to/ZigguratOS/zig-out/duos/fip.bin \
  rom-ziggurat-duos/fip.bin

(cd rom-ziggurat-duos &&
  sha256sum -c /path/to/ZigguratOS/zig-out/duos/fip.sha256)
```

The checksum must report `fip.bin: OK`. The old ZIP in this staging tree
still contains the original SDK FIP; do not use it for ZigguratOS.

Test the custom FIP:

1. Set the board switch to RISC-V and eMMC boot.
2. Remove the SD card.
3. Connect UART0 at `115200 8N1`, with flow control disabled.
4. Hold `recovery`, connect USB Type-C, then release `recovery`.
5. Confirm USB VID `0x3346` and PID `0x1000`.
6. Run the downloader.

```bash
cd /path/to/duo-flash
./usb_dl -s linux -c 181x -i ./rom-ziggurat-duos
```

The correct chip selector is `181x`; `cv181x` is not a valid `-c` value. The
repeated `Waiting for USB device connection` lines are part of BootROM/FSBL
download mode handling while the board enters and leaves recovery mode. They
are not an eMMC write error and their final state is not proof that anything
has been written to eMMC. Use this flow only to test the custom FIP; it does
not replace the persistent boot slots.

The expected UART sequence is SDK FSBL, SDK OpenSBI, and then ZigguratOS at
`0x80200000`. Once the shell prompt appears, test the implemented commands:

```text
echo hello
ls
mkdir test
touch test/a
ls test
rm test/a
```

Shell redirection is incomplete. Do not use an empty redirected file as proof
that `cat` wrote content correctly.

An initial UART log starting with `C.` indicates RISC-V startup; `B.` indicates
the ARM firmware started and the architecture switch or image selection is
wrong.

## Persistent eMMC installation

The DuoS eMMC boot partition layout is defined by the SDK itself. The board
configuration uses
`build/boards/cv181x/sg2000_milkv_duos_musl_riscv64_emmc/partition/partition_emmc.xml`;
the generated U-Boot partition layout in
`build/tools/common/image_tool/mkcvipart.py` is:

```text
mmcblk0boot0:
  offset 0x000000, size 1 MiB  -> fip
  offset 0x100000, size 1 MiB  -> fip_bak
```

`build/tools/common/image_tool/pack_images.py` creates `Boot.bin` by padding
the FIP to `0x800 * 512` bytes and writing it a second time. `Boot.bin` is
therefore exactly these two 1 MiB slots back to back. The ZigguratOS packer
performs the same operation, fills the unused part of each slot with `0xff`,
and verifies that both slots are identical.

Writing `Boot.bin` replaces the persistent boot firmware. Back up the existing
boot partition first and keep the USB BootROM recovery path available. Run the
commands below from the Linux system booted on the DuoS itself. Confirm the
eMMC boot partition name instead of assuming it: it is normally
`/dev/mmcblk0boot0` when booted from the DuoS eMMC, but an SD-card boot can
change the controller numbering. Do not substitute the whole-disk node
`/dev/mmcblk0`.

Inspect the device first:

```bash
lsblk -o NAME,TRAN,SIZE,TYPE,MODEL,SERIAL,MOUNTPOINTS
findmnt
ls -l /dev/mmcblk0boot0
cat /sys/block/mmcblk0boot0/size
cat /sys/block/mmcblk0boot0/force_ro
```

The size is reported in 512-byte sectors and must be at least `4096` for the
2 MiB image. eMMC boot partitions are commonly larger than that.

Back up the complete boot partition:

```bash
cd /path/to/duo-flash
sudo dd if=/dev/mmcblk0boot0 \
  of=boot0-backup.bin bs=1M status=progress
sha256sum boot0-backup.bin
```

Copy the verified `Boot.bin` from the development host to the DuoS by SCP, a
USB drive, or another transfer method. On the DuoS, unlock the boot partition,
write both slots, flush, and lock it again:

```bash
sudo sh -c 'echo 0 > /sys/block/mmcblk0boot0/force_ro'
sudo dd if=/path/to/ZigguratOS/zig-out/duos/Boot.bin \
  of=/dev/mmcblk0boot0 bs=1M count=2 conv=fsync status=progress
sudo blockdev --flushbufs /dev/mmcblk0boot0
sudo sh -c 'echo 1 > /sys/block/mmcblk0boot0/force_ro'
```

Power off fully, remove the USB recovery connection, set eMMC boot, and start
the board with UART attached. It should now enter ZigguratOS without USB
download.

To roll back, unlock the boot partition and restore the saved image:

```bash
sudo sh -c 'echo 0 > /sys/block/mmcblk0boot0/force_ro'
sudo dd if=/path/to/duo-flash/boot0-backup.bin \
  of=/dev/mmcblk0boot0 bs=1M conv=fsync status=progress
sudo blockdev --flushbufs /dev/mmcblk0boot0
sudo sh -c 'echo 1 > /sys/block/mmcblk0boot0/force_ro'
```

If the board no longer reaches the shell, the BootROM USB recovery path can
start a RAM image even when the eMMC boot slots are invalid. Keep the original
SDK FIP and the complete boot-partition backup available for recovery.

## SD-card variant

The images above target the eMMC FIP layout. For SD boot, obtain a known-good
SD FIP from the matching DuoS SDK configuration and pass it as
`DUO_BASE_FIP`. The resulting `fip.bin` belongs in the FAT boot partition used
by that SDK package. Do not mix an eMMC FIP with an SD boot flow.

## Implemented scope

- One RISC-V S-mode hart, SV39 paging, SBI timer, and PLIC.
- Independent DW APB UART0 driver at `0x04140000`, PLIC IRQ 44, 25 MHz.
- Embedded newc initramfs in kernel `.rodata`.
- tmpfs root and the existing shell and applications.
- No DuoS block, network, USB, camera, or multimedia drivers.

The kernel image must stay below `0x81000000`; both the linker and packaging
tool enforce the boundary.

## Validation boundary

Earlier bring-up records are historical observations and do not certify the
current source tree or image. This documentation update did not connect to a
board or execute a new QEMU regression. Validate generated payload checksums,
slot layout and image boundaries before deployment, then record the exact
image hash with UART results.

The acceptance sequence is FSBL/OpenSBI entry, paging activation, root
filesystem initialization, interactive shell, UART input and file commands.
A QEMU run cannot validate the DuoS UART, PLIC or chip-specific memory
attributes. A packaged image alone cannot prove successful boot.

C906 leaf PTE attribute bits must not be interpreted as physical page-number
bits; address extraction masks the Sv39 PPN. Trapframe CSR layout must match
the assembly save/restore contract. These are ongoing implementation contracts,
not a reason to reuse an old image's result as a current pass.

Bring-up traces are controlled by `board/duos/config.zig:boot_trace`, currently
false. For the separate native M-mode small-core target, use
[its ownership and validation contract](DUOS_SMALLCORE.md).
