/* start.S — Entry point: inizializza stack e BSS, poi chiama main */

.section .text.start
.global _start

_start:
    la   sp, __stack

    /* azzera la sezione .bss */
    la   a0, __bss_start
    la   a1, __bss_end
bss_loop:
    bge  a0, a1, bss_done
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    bss_loop
bss_done:

    call main

    /* segnala la fine al testbench/top scrivendo il codice di uscita a 0x20000000 */
    li   t0, 0x20000000
    sw   a0, 0(t0)

infinite:
    j infinite
