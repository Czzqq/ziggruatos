OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMAGE (rwx) : ORIGIN = 0x9f000000, LENGTH = 8M
}

SECTIONS
{
    . = ORIGIN(IMAGE);
    skernel = .;

    .text.boot : {
        stext_boot = .;
        KEEP(*(.text.machine.boot))
        *(.text.machine .text.machine.*)
        etext_boot = .;
    } > IMAGE

    .text : {
        stext = .;
        *(.text .text.*)
    } > IMAGE
    etext = .;

    .rodata ALIGN(0x1000) : {
        srodata = .;
        *(.rodata .rodata.* .srodata .srodata.*)
        erodata = .;
    } > IMAGE

    .data ALIGN(0x1000) : {
        sdata = .;
        *(.data .data.* .sdata .sdata.*)
        edata = .;
    } > IMAGE

    .bss ALIGN(0x1000) (NOLOAD) : {
        *(.bss.stack)
        sbss = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        ebss = .;
    } > IMAGE
    ekernel = ALIGN(0x1000);
    __reserved_end = 0xa0000000;
    __allocator_start = 0x9f800000;

    ASSERT(_start == ORIGIN(IMAGE), "reset entry must be raw image byte zero")
    ASSERT(ekernel <= __allocator_start, "kernel/BSS/stacks collide with allocator")
    ASSERT(__allocator_start < __reserved_end, "empty small-core allocator")

    /DISCARD/ : { *(.eh_frame .eh_frame.*) }
}
