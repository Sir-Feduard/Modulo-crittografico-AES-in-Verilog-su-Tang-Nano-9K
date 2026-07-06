/*
 * bootloader.v — Bootloader SPI per Tang Nano 9K
 *
 * Legge WORDS_TO_READ word (32 bit) dalla flash esterna all'offset FLASH_OFFSET
 * e le scrive nella BRAM della CPU tramite ram_we/ram_addr/ram_wdata.
 * Quando la lettura è completa alza boot_done e rimane fermo.
 *
 * Sequenza SPI all'avvio:
 *   1. 0xAB — Power-Up/Release from Deep Power-Down
 *   2. 0x66 — Enable Reset
 *   3. 0x99 — Reset Device  (+ attesa 1 ms per stabilizzazione interna)
 *   4. 0x03 — Read Data a partire da FLASH_OFFSET
 */

module hw_bootloader (
    input  wire clk,
    input  wire por_resetn,

    output reg  spi_csn,
    output reg  spi_clk,
    output reg  spi_mosi,
    input  wire spi_miso,

    output reg        ram_we,
    output reg [14:2] ram_addr,
    output reg [31:0] ram_wdata,

    output reg boot_done
);
    localparam FLASH_OFFSET  = 24'h100000;
    localparam WORDS_TO_READ = 8192;

    reg [31:0] shift_reg;
    reg  [7:0] bit_count;
    reg [15:0] word_count;
    reg [15:0] wait_count;
    reg  [4:0] state;

    // Stati per il comando 0xAB (power-up)
    localparam S_AB_FALL   = 0;
    localparam S_AB_RISE   = 1;
    localparam S_AB_FINISH = 2;
    localparam S_WAIT_AB   = 3;

    // Stati per il comando 0x66 (enable reset)
    localparam S_66_FALL   = 4;
    localparam S_66_RISE   = 5;
    localparam S_66_FINISH = 6;
    localparam S_WAIT_66   = 7;

    // Stati per il comando 0x99 (reset device)
    localparam S_99_FALL   = 8;
    localparam S_99_RISE   = 9;
    localparam S_99_FINISH = 10;
    localparam S_WAIT_99   = 11;

    // Stati per la lettura dati (0x03 + indirizzo + burst)
    localparam S_IDLE       = 12;
    localparam S_CMD_FALL   = 13;
    localparam S_CMD_RISE   = 14;
    localparam S_DAT_FALL   = 15;
    localparam S_DAT_RISE   = 16;
    localparam S_LATCH_DATA = 17;
    localparam S_DO_WRITE   = 18;
    localparam S_INC_ADDR   = 19;
    localparam S_DONE       = 20;

    always @(posedge clk) begin
        if (!por_resetn) begin
            state      <= S_AB_FALL;
            spi_csn    <= 1;
            spi_clk    <= 0;
            boot_done  <= 0;
            ram_we     <= 0;
            ram_addr   <= 0;
            ram_wdata  <= 0;
            word_count <= 0;
            shift_reg  <= {8'hAB, 24'h000000};
            bit_count  <= 8;
            wait_count <= 0;
        end else begin
            ram_we <= 0;

            case (state)

                // -----1. Power-Up (0xAB) ----------------------------------
                S_AB_FALL: begin
                    spi_csn   <= 0; spi_clk <= 0;
                    spi_mosi  <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};
                    bit_count <= bit_count - 1;
                    state     <= S_AB_RISE;
                end
                S_AB_RISE: begin
                    spi_clk <= 1;
                    if (bit_count == 0) state <= S_AB_FINISH;
                    else                state <= S_AB_FALL;
                end
                S_AB_FINISH: begin
                    spi_clk    <= 0;
                    wait_count <= 0;
                    state      <= S_WAIT_AB;
                end
                S_WAIT_AB: begin
                    // CS alto per rispettare il tCS del datasheet, poi pausa ~1 ms
                    spi_csn <= 1;
                    if (wait_count == 16'd27000) begin
                        shift_reg <= {8'h66, 24'h000000};
                        bit_count <= 8;
                        state     <= S_66_FALL;
                    end else wait_count <= wait_count + 1;
                end

                // ---- 2. Enable Reset (0x66) ----------------------------------------
                S_66_FALL: begin
                    spi_csn   <= 0; spi_clk <= 0;
                    spi_mosi  <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};
                    bit_count <= bit_count - 1;
                    state     <= S_66_RISE;
                end
                S_66_RISE: begin
                    spi_clk <= 1;
                    if (bit_count == 0) state <= S_66_FINISH;
                    else                state <= S_66_FALL;
                end
                S_66_FINISH: begin
                    spi_clk    <= 0;
                    wait_count <= 0;
                    state      <= S_WAIT_66;
                end
                S_WAIT_66: begin
                    // Pausa breve tra 0x66 e 0x99 per rispettare tSHSL
                    spi_csn <= 1;
                    if (wait_count == 10) begin
                        shift_reg <= {8'h99, 24'h000000};
                        bit_count <= 8;
                        state     <= S_99_FALL;
                    end else wait_count <= wait_count + 1;
                end

                // ---- 3. Reset Device (0x99) -----------------------------------
                S_99_FALL: begin
                    spi_csn   <= 0; spi_clk <= 0;
                    spi_mosi  <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};
                    bit_count <= bit_count - 1;
                    state     <= S_99_RISE;
                end
                S_99_RISE: begin
                    spi_clk <= 1;
                    if (bit_count == 0) state <= S_99_FINISH;
                    else                state <= S_99_FALL;
                end
                S_99_FINISH: begin
                    spi_clk    <= 0;
                    wait_count <= 0;
                    state      <= S_WAIT_99;
                end
                S_WAIT_99: begin
                    // ~1 ms per far completare il riavvio interno alla flash
                    spi_csn <= 1;
                    if (wait_count == 16'd27000) state <= S_IDLE;
                    else                         wait_count <= wait_count + 1;
                end

                // ----- 4. Lettura burst (0x03 + 24-bit addr) ----------------------
                S_IDLE: begin
                    spi_csn    <= 0; spi_clk <= 0;
                    shift_reg  <= {8'h03, FLASH_OFFSET};
                    bit_count  <= 32;
                    word_count <= 0;
                    ram_addr   <= 0;
                    state      <= S_CMD_FALL;
                end
                S_CMD_FALL: begin
                    spi_clk   <= 0;
                    spi_mosi  <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};
                    bit_count <= bit_count - 1;
                    state     <= S_CMD_RISE;
                end
                S_CMD_RISE: begin
                    spi_clk <= 1;
                    if (bit_count == 0) begin
                        bit_count <= 32;
                        state     <= S_DAT_FALL;
                    end else state <= S_CMD_FALL;
                end
                S_DAT_FALL: begin
                    spi_clk   <= 0;
                    bit_count <= bit_count - 1;
                    state     <= S_DAT_RISE;
                end
                S_DAT_RISE: begin
                    spi_clk   <= 1;
                    shift_reg <= {shift_reg[30:0], spi_miso};
                    if (bit_count == 0) state <= S_LATCH_DATA;
                    else                state <= S_DAT_FALL;
                end
                S_LATCH_DATA: begin
                    // La flash trasmette big-endian; inversione byte per little-endian RISC-V
                    spi_clk   <= 0;
                    ram_wdata <= {shift_reg[7:0], shift_reg[15:8],
                                  shift_reg[23:16], shift_reg[31:24]};
                    state <= S_DO_WRITE;
                end
                S_DO_WRITE: begin
                    ram_we     <= 1;
                    word_count <= word_count + 1;
                    if (word_count == WORDS_TO_READ - 1) state <= S_DONE;
                    else                                  state <= S_INC_ADDR;
                end
                S_INC_ADDR: begin
                    ram_addr  <= ram_addr + 1;
                    bit_count <= 32;
                    state     <= S_DAT_FALL;
                end

                // ------ Fine: CS alto e segnale di completamento ----------------------
                S_DONE: begin
                    spi_csn   <= 1;
                    boot_done <= 1;
                end

            endcase
        end
    end
endmodule
