OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0x80000000, LENGTH = 64M }
SECTIONS {
    . = ORIGIN(ram);
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ram
    .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > ram
    .data : { *(.data .data.*) *(.sdata .sdata.*) } > ram
    . = ALIGN(16);
    __global_pointer$ = . + 0x800;
    __bss_start = .;
    .bss (NOLOAD) : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) . = ALIGN(16); } > ram
    __bss_end = .;
    __stack_top = ORIGIN(ram) + LENGTH(ram);
    ASSERT(__bss_end + 0x10000 < __stack_top, "Bare-metal program overlaps stack")
    /DISCARD/ : { *(.comment) *(.eh_frame*) *(.note*) }
}
