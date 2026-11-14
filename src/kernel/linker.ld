OUTPUT_ARCH(riscv)
ENTRY(_start)

TEXT_ROM = 0x80300000;

SECTIONS
{
    . = 0x80200000;
    skernel = .; /* start of kernel */

    .text.boot : {
        stext_boot = .; /* start of text.boot */
        *(.text.boot)
        etext_boot = .;
    }

    .text : AT(TEXT_ROM){
        stext = .; /* start of text - inside section for correct alignment */
        *(.text .text.*)

        . = ALIGN(0x1000);
        _trampoline = .;
        *(trampsec)
        . = ALIGN(0x1000);
        ASSERT(. - _trampoline == 0x1000, "error: trampoline larger than one page");
    }
    etext = .; /* end of text - after section */

    . = ALIGN(4K);
    srodata = .; /* start of rodata */
    .rodata : AT(ADDR(.rodata)){
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }
    erodata = .;

    . = ALIGN(4K);
    sdata = .;
    .data : { /* start of data */
        *(.data .data.*)
        *(.sdata .sdata.*)
    }
    edata = .;

    . = ALIGN(4K);
    .bss : { /* start of bss */
        *(.bss.stack)
        sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
    }
    ebss = .;

    ekernel = .;

    /DISCARD/ : {
        *(.eh_frame)
    }
}
