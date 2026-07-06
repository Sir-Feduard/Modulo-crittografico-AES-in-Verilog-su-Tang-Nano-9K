/*
 * link.ld — Linker script per bare-metal RISC-V su Tang Nano 9K
 *
 * Tutta la memoria (codice + dati + stack + heap) vive nella BRAM da 32 KB
 * mappata a partire da 0x00000000. Lo stack cresce verso il basso a partire
 * da __stack; l'heap occupa la zona tra _end e __heap_end.
 */

ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS {
    .text : {
        *(.text.start)      /* entry point per primo */
        *(.text*)
        *(.rodata*)
    } > RAM

    .data : {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        __data_end = .;
    } > RAM

    .bss : {
        __bss_start = .;
        _bss_start  = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
        _bss_end  = .;
    } > RAM

    _end = .;
    __end = .;

    __stack    = 0x00007FFC;    /* top of stack (cresce verso il basso) */
    __heap_end = 0x00006000;    /* limite superiore heap */
}
