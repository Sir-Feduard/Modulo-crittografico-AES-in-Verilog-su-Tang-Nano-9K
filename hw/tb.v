/*
 * tb.v — Testbench per PicoRV32 + my_pcpi
 *
 * Simula l'intero sistema: CPU, PCPI, memoria RAM caricata da program.hex.
 * La "UART fake" intercetta le scritture a 0x10000000 e le stampa su console,
 * permettendo a printf di funzionare in simulazione.
 * L'output VCD viene salvato per analisi con GTKWave.
 */

`timescale 1ns / 1ps

module tb;

    // Clock a 100 MHz (periodo 10 ns) e reset iniziale
    reg clk    = 0;
    reg resetn = 0;

    always #5 clk = ~clk;

    initial begin
        repeat(4) @(posedge clk);
        resetn = 1;
    end

    // Timeout di sicurezza per evitare simulazioni infinite
    initial begin
        #20_000_000;
        $display("[TB] TIMEOUT — simulazione terminata forzatamente");
        $finish;
    end

    // Dump waveform per GTKWave
    initial begin
        $dumpfile("sim.vcd");
        $dumpvars(0, tb);
    end

    // RAM 32KB (4096 parole da 32 bit), mappata su BSRAM come in top.v
    reg [31:0] memory [0:8191];

    initial begin
        $readmemh("../sw/program.hex", memory);
        $display("[TB] Memoria caricata da program.hex");
    end

    // Segnali bus memoria CPU → RAM
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire  [3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // Segnali interfaccia PCPI
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // Istanza CPU — PCPI abilitato, MUL/DIV disabilitati (gestiti da my_pcpi)
    picorv32 #(
        .ENABLE_PCPI    (1),
        .ENABLE_MUL     (0),
        .ENABLE_DIV     (0),
        .BARREL_SHIFTER (1),
        .COMPRESSED_ISA (0)
    ) cpu (
        .clk      (clk),
        .resetn   (resetn),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr (mem_addr),
        .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn (pcpi_insn),
        .pcpi_rs1  (pcpi_rs1),
        .pcpi_rs2  (pcpi_rs2),
        .pcpi_wr   (pcpi_wr),
        .pcpi_rd   (pcpi_rd),
        .pcpi_wait (pcpi_wait),
        .pcpi_ready(pcpi_ready)
    );

    // Istanza acceleratore AES via PCPI
    my_pcpi pcpi_inst (
        .clk        (clk),
        .resetn     (resetn),
        .pcpi_valid (pcpi_valid),
        .pcpi_insn  (pcpi_insn),
        .pcpi_rs1   (pcpi_rs1),
        .pcpi_rs2   (pcpi_rs2),
        .pcpi_wr    (pcpi_wr),
        .pcpi_rd    (pcpi_rd),
        .pcpi_wait  (pcpi_wait),
        .pcpi_ready (pcpi_ready)
    );

    // Mappa indirizzi:
    //   0x00000000 – 0x00003FFF  RAM 16KB
    //   0x10000000               UART TX fake (byte → console)
    //   0x20000000               EXIT (termina la simulazione)
    localparam UART_ADDR = 32'h1000_0000;
    localparam EXIT_ADDR = 32'h2000_0000;

    always @(posedge clk) begin
        mem_ready <= 0;
        mem_rdata <= 32'hx;

        if (mem_valid && !mem_ready) begin

            if (mem_addr == EXIT_ADDR) begin
                $display("[TB] Programma terminato con codice %0d", mem_wdata);
                $finish;
            end

            else if (mem_addr == UART_ADDR) begin
                if (|mem_wstrb)
                    $write("%c", mem_wdata[7:0]);
                mem_ready <= 1;
            end

            else if (mem_addr < 32'h0000_8000) begin
                mem_ready <= 1;
                mem_rdata <= memory[mem_addr[14:2]];
                if (mem_wstrb[0]) memory[mem_addr[14:2]][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) memory[mem_addr[14:2]][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) memory[mem_addr[14:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) memory[mem_addr[14:2]][31:24] <= mem_wdata[31:24];
            end

            else begin
                $display("[TB] ERRORE: accesso a indirizzo non mappato 0x%08X", mem_addr);
                mem_ready <= 1;
                mem_rdata <= 32'hDEAD_BEEF;
            end
        end
    end

    // Monitor PCPI: log ogni risposta dell'acceleratore
    always @(posedge clk) begin
        if (pcpi_ready && pcpi_wr)
            $display("[PCPI] rs1=0x%08X  rs2[7:0]=0x%02X  → rd=0x%08X",
                     pcpi_rs1, pcpi_rs2[7:0], pcpi_rd);
    end

endmodule
