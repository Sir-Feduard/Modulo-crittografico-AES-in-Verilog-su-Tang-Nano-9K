/*
 * top.v — Top-level per Tang Nano 9K
 *
 * Sequenza di avvio:
 *   1. POR: reset sincrono esteso per stabilità elettrica al cold-boot
 *   2. Bootloader: legge il firmware dalla flash SPI e lo carica in BRAM
 *   3. CPU: PicoRV32 parte non appena boot_done è alto
 *
 * Mappa indirizzi:
 *   0x00000000 – 0x00007FFF   BRAM 32 KB (istruzioni + dati)
 *   0x10000000                UART TX (scrittura byte → trasmissione seriale)
 *   0x20000000                EXIT (segnala fine programma, accende LED)
 */

module top (
    input  wire clk,
    input  wire btn_reset,
    output wire uart_tx,
    output reg  led,

    // Pin SPI per la flash esterna
    output wire spi_csn,
    output wire spi_clk,
    output wire spi_mosi,
    input  wire spi_miso
);

    // ----Reset -------------------------------------------------------
    // Doppio flip-flop per sincronizzare btn_reset al dominio di clock
    reg reset_ff1, reset_ff2;
    always @(posedge clk)
        {reset_ff2, reset_ff1} <= {reset_ff1, btn_reset};

    // Contatore POR: mantiene il reset attivo per 2^17 cicli dopo l'accensione
    reg [17:0] por_cnt    = 0;
    reg        por_resetn = 0;
    always @(posedge clk) begin
        if (!reset_ff2) begin
            por_cnt    <= 0;
            por_resetn <= 0;
        end else if (!por_cnt[17]) begin
            por_cnt    <= por_cnt + 1;
            por_resetn <= 0;
        end else begin
            por_resetn <= 1;
        end
    end

    // ----Bootloader ------------------------------------------------------
    wire        boot_we;
    wire [14:2] boot_addr;
    wire [31:0] boot_wdata;
    wire        boot_done;

    hw_bootloader boot_inst (
        .clk       (clk),
        .por_resetn(por_resetn),
        .spi_csn   (spi_csn),
        .spi_clk   (spi_clk),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .ram_we    (boot_we),
        .ram_addr  (boot_addr),
        .ram_wdata (boot_wdata),
        .boot_done (boot_done)
    );

    // La CPU parte solo quando il POR è finito e il firmware è in BRAM
    wire resetn = por_resetn & boot_done;

    // ------Memoria BRAM 32 KB ----------------------------------------------
    (* ram_style = "block" *)
    reg [31:0] memory [0:8191];

    // Bus memoria CPU
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire  [3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // ----- Interfaccia PCPI (coprocessore) --------------------------------------
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // -------UART TX -------------------------------------------------------------
    // 27 MHz / 115200 baud = 234 cicli per bit
    reg [7:0] uart_data;
    reg       uart_valid;
    wire      uart_busy;

    uart_tx #(.CLKS_PER_BIT(234)) uart_inst (
        .clk    (clk),
        .resetn (resetn),
        .i_data (uart_data),
        .i_valid(uart_valid),
        .o_busy (uart_busy),
        .o_tx   (uart_tx)
    );

    // ---- CPU PicoRV32 ----------------------------------------------------------
    picorv32 #(
        .ENABLE_PCPI    (1),
        .ENABLE_MUL     (0),
        .ENABLE_DIV     (0),
        .BARREL_SHIFTER (1),
        .COMPRESSED_ISA (0)
    ) cpu (
        .clk      (clk),    .resetn   (resetn),
        .mem_valid(mem_valid), .mem_instr(mem_instr),
        .mem_ready(mem_ready), .mem_addr (mem_addr),
        .mem_rdata(mem_rdata), .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .pcpi_valid(pcpi_valid), .pcpi_insn (pcpi_insn),
        .pcpi_rs1  (pcpi_rs1),   .pcpi_rs2  (pcpi_rs2),
        .pcpi_wr   (pcpi_wr),    .pcpi_rd   (pcpi_rd),
        .pcpi_wait (pcpi_wait),  .pcpi_ready(pcpi_ready)
    );

    // --- Acceleratore AES (PCPI) -------------------------------------------------
    my_pcpi aes_inst (
        .clk       (clk),        .resetn    (resetn),
        .pcpi_valid(pcpi_valid), .pcpi_insn (pcpi_insn),
        .pcpi_rs1  (pcpi_rs1),   .pcpi_rs2  (pcpi_rs2),
        .pcpi_wr   (pcpi_wr),    .pcpi_rd   (pcpi_rd),
        .pcpi_wait (pcpi_wait),  .pcpi_ready(pcpi_ready)
    );

    // --- Bus controller ------------------------------------------------------------
    localparam UART_ADDR   = 32'h1000_0000;
    localparam EXIT_ADDR   = 32'h2000_0000;
    localparam S_IDLE      = 2'd0;
    localparam S_UART_WAIT = 2'd1;

    reg [1:0] state;
    reg [7:0] uart_byte_latch;
    reg       bram_wait = 0;

    always @(posedge clk) begin

        // Fase 1: bootloader attivo — scrivi firmware in BRAM, CPU in reset
        if (!boot_done) begin
            if (boot_we) memory[boot_addr] <= boot_wdata;
            mem_ready       <= 0;
            uart_valid      <= 0;
            uart_byte_latch <= 0;
            led             <= 1;   // LED spento durante il caricamento
            state           <= S_IDLE;
            bram_wait       <= 0;

        // Fase 2: POR/reset manuale — firmware caricato, CPU ancora ferma
        end else if (!resetn) begin
            mem_ready       <= 0;
            uart_valid      <= 0;
            uart_byte_latch <= 0;
            led             <= 1;
            state           <= S_IDLE;
            bram_wait       <= 0;

        // Fase 3: esecuzione normale
        end else begin
            mem_ready  <= 0;
            uart_valid <= 0;

            case (state)
                S_IDLE: begin
                    if (mem_valid && !mem_ready) begin

                        if (mem_addr == EXIT_ADDR) begin
                            led       <= 0;     // LED acceso fisso: programma completato
                            mem_ready <= 1;
                        end

                        else if (mem_addr == UART_ADDR && |mem_wstrb) begin
                            uart_byte_latch <= mem_wdata[7:0];
                            state           <= S_UART_WAIT;
                        end

                        else if (mem_addr < 32'h0000_8000) begin
                            if (|mem_wstrb) begin
                                mem_ready <= 1;
                                if (mem_wstrb[0]) memory[mem_addr[14:2]][ 7: 0] <= mem_wdata[ 7: 0];
                                if (mem_wstrb[1]) memory[mem_addr[14:2]][15: 8] <= mem_wdata[15: 8];
                                if (mem_wstrb[2]) memory[mem_addr[14:2]][23:16] <= mem_wdata[23:16];
                                if (mem_wstrb[3]) memory[mem_addr[14:2]][31:24] <= mem_wdata[31:24];
                            end else begin
                                // Le BSRAM Gowin hanno un ciclo di latenza in lettura
                                if (!bram_wait) begin
                                    bram_wait <= 1;
                                end else begin
                                    bram_wait <= 0;
                                    mem_ready <= 1;
                                    mem_rdata <= memory[mem_addr[14:2]];
                                end
                            end
                        end

                        else begin
                            // Indirizzo non mappato
                            mem_ready <= 1;
                            mem_rdata <= 32'hDEAD_BEEF;
                        end
                    end
                end

                // Aspetta che la UART sia libera, poi invia il byte
                S_UART_WAIT: begin
                    if (!uart_busy) begin
                        uart_data  <= uart_byte_latch;
                        uart_valid <= 1;
                        mem_ready  <= 1;
                        state      <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
