#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>

/*
 * syscalls.c — Stub di sistema per picolibc su bare-metal RISC-V
 *
 * Collega printf/putchar alla UART hardware mappata a 0x10000000.
 * _sbrk gestisce l'heap tra _end (fine BSS) e __heap_end (da linker script).
 * Tutte le altre syscall sono stub minimi richiesti dal linker.
 */

#define UART_TX_ADDR ((volatile unsigned int *)0x10000000)

/* Callback per picolibc tinystdio: scrive un byte sulla UART */
static int uart_putc(char c, FILE *f) {
    (void)f;
    *UART_TX_ADDR = (unsigned int)c;
    return (unsigned char)c;
}

static FILE __stdio = FDEV_SETUP_STREAM(uart_putc, NULL, NULL, _FDEV_SETUP_WRITE);

FILE *const stdout = &__stdio;
FILE *const stderr = &__stdio;
FILE *const stdin  = &__stdio;

/* Fallback _write per compatibilità con altri runtime */
int _write(int fd, const char *buf, int len) {
    (void)fd;
    for (int i = 0; i < len; i++)
        *UART_TX_ADDR = (unsigned int)buf[i];
    return len;
}

/* Heap allocator: avanza heap_ptr fino al limite __heap_end del linker script */
extern char _end;
extern char __heap_end;
static char *heap_ptr = 0;

void *_sbrk(int incr) {
    if (heap_ptr == 0) heap_ptr = &_end;
    char *prev = heap_ptr;
    if ((heap_ptr + incr) > &__heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_ptr += incr;
    return (void *)prev;
}

/* Stub syscall richiesti dal linker */
int _close(int fd)                         { (void)fd; return -1; }
int _fstat(int fd, struct stat *st)        { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd)                        { (void)fd; return 1; }
int _lseek(int fd, int offset, int whence) { (void)fd; (void)offset; (void)whence; return 0; }
int _read(int fd, char *buf, int len)      { (void)fd; (void)buf; (void)len; return 0; }
int _kill(int pid, int sig)                { (void)pid; (void)sig; return -1; }
int _getpid(void)                          { return 1; }

void _exit(int status) {
    volatile unsigned int *exit_addr = (volatile unsigned int *)0x20000000;
    *exit_addr = (unsigned int)status;
    while (1);
}
