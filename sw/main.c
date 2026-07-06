#include <stdio.h>
#include <stdint.h>

/*
 * Interfaccia verso l'acceleratore AES hardware via istruzione custom PCPI.
 * L'opcode è 0x0B; rs1 codifica comando (bit [1:0]) e indice word (bit [3:2]).
 */
#define CMD_WRITE_KEY  0
#define CMD_WRITE_TEXT 1
#define CMD_START      2
#define CMD_READ_TEXT  3

static inline uint32_t hw_aes_inst(uint32_t rs1_val, uint32_t rs2_val) {
    uint32_t rd_val;
    __asm__ volatile (
        ".insn r 0x0B, 0, 0, %0, %1, %2"
        : "=r" (rd_val)
        : "r" (rs1_val), "r" (rs2_val)
    );
    return rd_val;
}

static inline uint32_t pack_word(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] <<  8) |  (uint32_t)b[3];
}

static inline void unpack_word(uint32_t w, uint8_t *b) {
    b[0] = (w >> 24) & 0xFF;
    b[1] = (w >> 16) & 0xFF;
    b[2] = (w >>  8) & 0xFF;
    b[3] =  w        & 0xFF;
}

/* Cifra un blocco AES-128: carica chiave e plaintext, avvia, legge ciphertext */
void cifra_blocco_aes(const uint8_t key[16], const uint8_t in[16], uint8_t out[16]) {
    for (int i = 0; i < 4; i++)
        hw_aes_inst((i << 2) | CMD_WRITE_KEY, pack_word(&key[i * 4]));

    for (int i = 0; i < 4; i++)
        hw_aes_inst((i << 2) | CMD_WRITE_TEXT, pack_word(&in[i * 4]));

    hw_aes_inst(CMD_START, 0);

    for (int i = 0; i < 4; i++)
        unpack_word(hw_aes_inst((i << 2) | CMD_READ_TEXT, 0), &out[i * 4]);
}

/* Stampa un buffer in esadecimale con descrizione */
static void print_hex(const char *label, const uint8_t *data, int len) {
    printf("%s: ", label);
    for (int i = 0; i < len; i++)
        printf("%02X", data[i]);
    printf("\r\n");
}

static int compare(const uint8_t *a, const uint8_t *b, int len) {
    for (int i = 0; i < len; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

/*
 * Suite di test AES-128:
 *   Test 1 — vettore ufficiale NIST FIPS-197 Appendice B
 *   Test 2 — chiave e testo tutti zero
 *   Test 3 — due cifrature consecutive (verifica reset stato interno)
 */
int main(void) {
    printf("=== Test Acceleratore AES Hardware (PCPI) ===\r\n\n");

    /* Test 1: NIST FIPS-197 Appendice B */
    const uint8_t key1[16] = {
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C
    };
    const uint8_t plain1[16] = {
        0x32, 0x43, 0xF6, 0xA8, 0x88, 0x5A, 0x30, 0x8D,
        0x31, 0x31, 0x98, 0xA2, 0xE0, 0x37, 0x07, 0x34
    };
    const uint8_t expected1[16] = {
        0x39, 0x25, 0x84, 0x1D, 0x02, 0xDC, 0x09, 0xFB,
        0xDC, 0x11, 0x85, 0x97, 0x19, 0x6A, 0x0B, 0x32
    };
    uint8_t result1[16];

    printf("-- Test 1: vettore NIST FIPS-197 Appendice B --\r\n");
    print_hex("Chiave  ", key1, 16);
    print_hex("Input   ", plain1, 16);
    cifra_blocco_aes(key1, plain1, result1);
    print_hex("Output  ", result1, 16);
    print_hex("Atteso  ", expected1, 16);
    printf("Risultato: %s\r\n\n", compare(result1, expected1, 16) ? "OK v" : "ERRORE x");

    /* Test 2: chiave e testo tutti zero */
    const uint8_t key2[16]      = {0};
    const uint8_t plain2[16]    = {0};
    const uint8_t expected2[16] = {
        0x66, 0xE9, 0x4B, 0xD4, 0xEF, 0x8A, 0x2C, 0x3B,
        0x88, 0x4C, 0xFA, 0x59, 0xCA, 0x34, 0x2B, 0x2E
    };
    uint8_t result2[16];

    printf("-- Test 2: chiave e testo tutti zero --\r\n");
    print_hex("Chiave  ", key2, 16);
    print_hex("Input   ", plain2, 16);
    cifra_blocco_aes(key2, plain2, result2);
    print_hex("Output  ", result2, 16);
    print_hex("Atteso  ", expected2, 16);
    printf("Risultato: %s\r\n\n", compare(result2, expected2, 16) ? "OK v" : "ERRORE x");

    /* Test 3: due cifrature consecutive (stesso blocco, risultato deve essere identico) */
    uint8_t result3a[16], result3b[16];
    printf("-- Test 3: due cifrature consecutive (stesso blocco) --\r\n");
    cifra_blocco_aes(key1, plain1, result3a);
    cifra_blocco_aes(key1, plain1, result3b);
    print_hex("Prima   ", result3a, 16);
    print_hex("Seconda ", result3b, 16);
    printf("Risultato: %s\r\n\n", compare(result3a, result3b, 16) ? "OK v (identici)" : "ERRORE x (diversi)");

    printf("=== Fine test ===\r\n");
    return 0;
}
