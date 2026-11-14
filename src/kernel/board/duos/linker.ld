OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;
    skernel = .;

    .text.boot : {
        stext_boot = .;
        *(.text.boot)
        etext_boot = .;
    }

    .text : {
        stext = .;
        *(.text .text.*)

        . = ALIGN(0x1000);
        _trampoline = .;
        *(trampsec)
        . = ALIGN(0x1000);
        ASSERT(. - _trampoline == 0x1000, "error: trampoline larger than one page");
    }
    etext = .;

    . = ALIGN(4K);
    srodata = .;
    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }
    erodata = .;

    . = ALIGN(4K);
    sdata = .;
    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }
    edata = .;

    . = ALIGN(4K);
    .bss : {
        *(.bss.stack)
        sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
    }
    ebss = .;

    . = ALIGN(4K);
    ekernel = .;

    ASSERT(ekernel <= 0x81000000, "DuoS payload collides with kernel memory")

    /DISCARD/ : {
        *(.eh_frame)
    }
}
