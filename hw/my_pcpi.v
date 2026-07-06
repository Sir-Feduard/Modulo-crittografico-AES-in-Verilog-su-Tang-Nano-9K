/*
 * my_pcpi.v — Acceleratore AES-128 via interfaccia PCPI di PicoRV32
 *
 * Decodifica l'opcode custom 0x0B (campo insn[6:0] = 7'b0001011).
 * Il campo rs1 codifica il comando nei bit [1:0] e l'indice di parola nei bit [3:2]:
 *
 *   CMD 0 — WRITE_KEY:  scrive la word rs2 nel registro chiave all'indice idx
 *   CMD 1 — WRITE_TEXT: scrive la word rs2 nel registro plaintext all'indice idx
 *   CMD 2 — START:      avvia la cifratura AES (CPU bloccata fino a done)
 *   CMD 3 — READ_TEXT:  legge la word di ciphertext all'indice idx in rd
 *
 * Contiene quattro moduli: my_pcpi, aes_core, aes_key_expansion,
 * aes_mixcolumn, aes_sbox_bram.
 */

module my_pcpi (
    input  wire        clk,
    input  wire        resetn,
    input  wire        pcpi_valid,
    input  wire [31:0] pcpi_insn,
    input  wire [31:0] pcpi_rs1,
    input  wire [31:0] pcpi_rs2,
    output reg         pcpi_wr,
    output reg  [31:0] pcpi_rd,
    output reg         pcpi_wait,
    output reg         pcpi_ready
);
    wire is_my_opcode = (pcpi_insn[6:0] == 7'b0001011);
    wire start = pcpi_valid && is_my_opcode;

    wire [1:0] comando = pcpi_rs1[1:0];
    wire [1:0] idx     = pcpi_rs1[3:2];

    reg [1:0] stato;

    reg [31:0] mem_chiave_0, mem_chiave_1, mem_chiave_2, mem_chiave_3;
    reg [31:0] mem_testo_0,  mem_testo_1,  mem_testo_2,  mem_testo_3;

    reg          aes_start;
    wire         aes_done;
    wire [127:0] aes_out;

    wire [127:0] chiave_completa = {mem_chiave_0, mem_chiave_1, mem_chiave_2, mem_chiave_3};
    wire [127:0] testo_completo  = {mem_testo_0,  mem_testo_1,  mem_testo_2,  mem_testo_3};

    aes_core mio_core_aes (
        .clk     (clk),
        .resetn  (resetn),
        .start   (aes_start),
        .key     (chiave_completa),
        .data_in (testo_completo),
        .data_out(aes_out),
        .done    (aes_done)
    );

    // pcpi_wait combinatorio: mantiene la CPU in stallo per tutta la durata del comando
    always @(*) pcpi_wait = start;

    // Macchina a stati principale:
    //   0 → decodifica comando e gestisce scritture/letture in un ciclo
    //   1 → pulse di aes_start verso il core
    //   2 → attende aes_done e cattura il risultato
    //   3 → attende che la CPU abbassi pcpi_valid prima di tornare a 0
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            stato <= 0;
            pcpi_ready <= 0;
            pcpi_wr    <= 0;
            pcpi_rd    <= 0;
            aes_start  <= 0;
            mem_chiave_0 <= 0; mem_chiave_1 <= 0;
            mem_chiave_2 <= 0; mem_chiave_3 <= 0;
            mem_testo_0  <= 0; mem_testo_1  <= 0;
            mem_testo_2  <= 0; mem_testo_3  <= 0;
        end else begin
            pcpi_ready <= 0;
            pcpi_wr    <= 0;

            if (stato == 0) begin
                aes_start <= 0;
                if (start) begin
                    if (comando == 2'd0) begin
                        if      (idx == 2'd0) mem_chiave_0 <= pcpi_rs2;
                        else if (idx == 2'd1) mem_chiave_1 <= pcpi_rs2;
                        else if (idx == 2'd2) mem_chiave_2 <= pcpi_rs2;
                        else if (idx == 2'd3) mem_chiave_3 <= pcpi_rs2;
                        pcpi_ready <= 1;
                        stato <= 3;
                    end else if (comando == 2'd1) begin
                        if      (idx == 2'd0) mem_testo_0 <= pcpi_rs2;
                        else if (idx == 2'd1) mem_testo_1 <= pcpi_rs2;
                        else if (idx == 2'd2) mem_testo_2 <= pcpi_rs2;
                        else if (idx == 2'd3) mem_testo_3 <= pcpi_rs2;
                        pcpi_ready <= 1;
                        stato <= 3;
                    end else if (comando == 2'd2) begin
                        stato <= 1;
                    end else if (comando == 2'd3) begin
                        pcpi_wr    <= 1;
                        pcpi_ready <= 1;
                        case (idx)
                            2'd0: pcpi_rd <= mem_testo_0;
                            2'd1: pcpi_rd <= mem_testo_1;
                            2'd2: pcpi_rd <= mem_testo_2;
                            2'd3: pcpi_rd <= mem_testo_3;
                            default: pcpi_rd <= 32'd0;
                        endcase
                        stato <= 3;
                    end
                end
            end else if (stato == 1) begin
                aes_start <= 1;
                stato <= 2;
            end else if (stato == 2) begin
                aes_start <= 0;
                if (aes_done) begin
                    mem_testo_0 <= aes_out[127:96];
                    mem_testo_1 <= aes_out[95:64];
                    mem_testo_2 <= aes_out[63:32];
                    mem_testo_3 <= aes_out[31:0];
                    pcpi_ready  <= 1;
                    stato <= 3;
                end
            end else if (stato == 3) begin
                if (!start) stato <= 0;
            end
        end
    end
endmodule


/*
 * aes_core — Pipeline AES-128 a 10 round
 *
 * SubBytes è serializzato su 4 BRAM condivise (4 byte per ciclo = 4 cicli per round).
 * ShiftRows è cablato in assign. MixColumns è istanziato per le 4 colonne in parallelo.
 * L'espansione della chiave avanza di un round per volta tramite aes_key_expansion.
 */
module aes_core (
    input  wire         clk,
    input  wire         resetn,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] data_in,
    output reg  [127:0] data_out,
    output reg          done
);
    localparam IDLE           = 3'b000;
    localparam WAIT_KEY       = 3'b001;
    localparam INIT           = 3'b010;
    localparam CALC_SUB       = 3'b011;
    localparam WAIT_EXPANSION = 3'b100;
    localparam CALC_P1        = 3'b101;
    localparam CALC_P2        = 3'b110;

    reg [2:0]   stato_attuale;
    reg [3:0]   round_counter;
    reg [127:0] state;
    reg [127:0] state_mid;

    reg [2:0]   sub_cnt;
    reg [127:0] subbytes_reg;

    wire [127:0] round_key;
    wire         key_ready;
    reg          key_init;
    reg          key_enable;

    // Quattro S-Box condivise: processano un gruppo di 4 byte per ciclo (mux su sub_cnt)
    reg  [7:0] sb_in_0, sb_in_1, sb_in_2, sb_in_3;
    wire [7:0] sb_out_w [0:3];

    always @(*) begin
        case (sub_cnt[1:0])
            2'd0: begin
                sb_in_0 = state[7:0];   sb_in_1 = state[15:8];
                sb_in_2 = state[23:16]; sb_in_3 = state[31:24];
            end
            2'd1: begin
                sb_in_0 = state[39:32]; sb_in_1 = state[47:40];
                sb_in_2 = state[55:48]; sb_in_3 = state[63:56];
            end
            2'd2: begin
                sb_in_0 = state[71:64]; sb_in_1 = state[79:72];
                sb_in_2 = state[87:80]; sb_in_3 = state[95:88];
            end
            2'd3: begin
                sb_in_0 = state[103:96];  sb_in_1 = state[111:104];
                sb_in_2 = state[119:112]; sb_in_3 = state[127:120];
            end
            default: begin
                sb_in_0 = 8'h00; sb_in_1 = 8'h00;
                sb_in_2 = 8'h00; sb_in_3 = 8'h00;
            end
        endcase
    end

    aes_sbox_bram sb_inst_0 (.clk(clk), .in_byte(sb_in_0), .out_byte(sb_out_w[0]));
    aes_sbox_bram sb_inst_1 (.clk(clk), .in_byte(sb_in_1), .out_byte(sb_out_w[1]));
    aes_sbox_bram sb_inst_2 (.clk(clk), .in_byte(sb_in_2), .out_byte(sb_out_w[2]));
    aes_sbox_bram sb_inst_3 (.clk(clk), .in_byte(sb_in_3), .out_byte(sb_out_w[3]));

    wire [127:0] shiftrows_out;
    wire [127:0] mixcols_out;

    // ShiftRows cablato: rotazione ciclica delle righe della matrice AES 4×4
    assign shiftrows_out = {
        subbytes_reg[127:120], subbytes_reg[87:80],   subbytes_reg[47:40],   subbytes_reg[7:0],
        subbytes_reg[95:88],   subbytes_reg[55:48],   subbytes_reg[15:8],    subbytes_reg[103:96],
        subbytes_reg[63:56],   subbytes_reg[23:16],   subbytes_reg[111:104], subbytes_reg[71:64],
        subbytes_reg[31:24],   subbytes_reg[119:112], subbytes_reg[79:72],   subbytes_reg[39:32]
    };

    aes_mixcolumn mc0 (.col_in(state_mid[127:96]), .col_out(mixcols_out[127:96]));
    aes_mixcolumn mc1 (.col_in(state_mid[95:64]),  .col_out(mixcols_out[95:64]));
    aes_mixcolumn mc2 (.col_in(state_mid[63:32]),  .col_out(mixcols_out[63:32]));
    aes_mixcolumn mc3 (.col_in(state_mid[31:0]),   .col_out(mixcols_out[31:0]));

    aes_key_expansion key_exp (
        .clk      (clk),
        .resetn   (resetn),
        .init     (key_init),
        .enable   (key_enable),
        .key      (key),
        .round_key(round_key),
        .key_ready(key_ready)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            stato_attuale <= IDLE;
            done          <= 0;
            data_out      <= 0;
            round_counter <= 0;
            state         <= 0;
            state_mid     <= 0;
            key_init      <= 0;
            key_enable    <= 0;
            sub_cnt       <= 0;
            subbytes_reg  <= 0;
        end else begin
            done       <= 0;
            key_init   <= 0;
            key_enable <= 0;

            case (stato_attuale)
                IDLE: begin
                    state <= 128'b0;
                    if (start) begin
                        round_counter <= 0;
                        sub_cnt       <= 0;
                        key_init      <= 1;
                        stato_attuale <= WAIT_KEY;
                    end
                end

                WAIT_KEY: begin
                    if (key_ready) stato_attuale <= INIT;
                end

                // AddRoundKey iniziale: XOR plaintext con chiave round 0
                INIT: begin
                    state         <= data_in ^ round_key;
                    round_counter <= 1;
                    stato_attuale <= CALC_SUB;
                end

                // SubBytes serializzato: 4 byte per ciclo, 1 ciclo di latenza BRAM
                CALC_SUB: begin
                    if (sub_cnt > 0 && sub_cnt <= 4) begin
                        case (sub_cnt - 1)
                            3'd0: subbytes_reg[31:0]   <= {sb_out_w[3], sb_out_w[2], sb_out_w[1], sb_out_w[0]};
                            3'd1: subbytes_reg[63:32]  <= {sb_out_w[3], sb_out_w[2], sb_out_w[1], sb_out_w[0]};
                            3'd2: subbytes_reg[95:64]  <= {sb_out_w[3], sb_out_w[2], sb_out_w[1], sb_out_w[0]};
                            3'd3: subbytes_reg[127:96] <= {sb_out_w[3], sb_out_w[2], sb_out_w[1], sb_out_w[0]};
                        endcase
                    end
                    if (sub_cnt == 4) begin
                        if (round_counter < 11) begin
                            key_enable    <= 1;
                            stato_attuale <= WAIT_EXPANSION;
                        end
                    end else
                        sub_cnt <= sub_cnt + 1;
                end

                WAIT_EXPANSION: begin
                    if (key_ready) stato_attuale <= CALC_P1;
                end

                // ShiftRows: il risultato è cablato, basta latching in state_mid
                CALC_P1: begin
                    state_mid     <= shiftrows_out;
                    stato_attuale <= CALC_P2;
                end

                // MixColumns + AddRoundKey (round 1–9); solo AddRoundKey all'ultimo round
                CALC_P2: begin
                    if (round_counter < 10) begin
                        state         <= mixcols_out ^ round_key;
                        round_counter <= round_counter + 1;
                        sub_cnt       <= 0;
                        stato_attuale <= CALC_SUB;
                    end else begin
                        data_out      <= state_mid ^ round_key;
                        done          <= 1;
                        stato_attuale <= IDLE;
                    end
                end

                default: stato_attuale <= IDLE;
            endcase
        end
    end
endmodule


/*
 * aes_key_expansion — Espansione chiave AES-128 round per round
 *
 * Con init=1 carica la chiave originale come round key 0 (key_ready=1 il ciclo dopo).
 * Con enable=1 calcola la round key successiva usando le 4 BRAM S-Box (1 ciclo latenza).
 * Il modulo avanza di un round per volta; aes_core lo pilota a ogni round.
 */
module aes_key_expansion (
    input  wire         clk,
    input  wire         resetn,
    input  wire         init,
    input  wire         enable,
    input  wire [127:0] key,
    output reg  [127:0] round_key,
    output reg          key_ready
);
    reg [3:0] round_counter;
    reg       computing;

    wire [31:0] w0 = round_key[127:96];
    wire [31:0] w1 = round_key[95:64];
    wire [31:0] w2 = round_key[63:32];
    wire [31:0] w3 = round_key[31:0];

    wire [31:0] sub_w3;
    reg  [31:0] rcon_val;

    // RotWord + SubWord su w3 tramite 4 BRAM (latenza 1 ciclo)
    aes_sbox_bram sb0 (.clk(clk), .in_byte(w3[23:16]), .out_byte(sub_w3[31:24]));
    aes_sbox_bram sb1 (.clk(clk), .in_byte(w3[15:8]),  .out_byte(sub_w3[23:16]));
    aes_sbox_bram sb2 (.clk(clk), .in_byte(w3[7:0]),   .out_byte(sub_w3[15:8]));
    aes_sbox_bram sb3 (.clk(clk), .in_byte(w3[31:24]), .out_byte(sub_w3[7:0]));

    always @(*) begin
        case (round_counter)
            1:  rcon_val = 32'h01000000;
            2:  rcon_val = 32'h02000000;
            3:  rcon_val = 32'h04000000;
            4:  rcon_val = 32'h08000000;
            5:  rcon_val = 32'h10000000;
            6:  rcon_val = 32'h20000000;
            7:  rcon_val = 32'h40000000;
            8:  rcon_val = 32'h80000000;
            9:  rcon_val = 32'h1b000000;
            10: rcon_val = 32'h36000000;
            default: rcon_val = 32'h00000000;
        endcase
    end

    wire [31:0] temp   = sub_w3 ^ rcon_val;
    wire [31:0] next_w0 = w0 ^ temp;
    wire [31:0] next_w1 = w1 ^ next_w0;
    wire [31:0] next_w2 = w2 ^ next_w1;
    wire [31:0] next_w3 = w3 ^ next_w2;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            round_counter <= 0;
            round_key     <= 0;
            computing     <= 0;
            key_ready     <= 0;
        end else begin
            key_ready <= 0;
            if (init) begin
                round_key     <= key;
                round_counter <= 1;
                key_ready     <= 1;
            end else if (enable && !computing) begin
                computing <= 1;
            end else if (computing) begin
                round_key     <= {next_w0, next_w1, next_w2, next_w3};
                round_counter <= round_counter + 1;
                computing     <= 0;
                key_ready     <= 1;
            end
        end
    end
endmodule


/*
 * aes_mixcolumn — MixColumns su una singola colonna (32 bit)
 *
 * Moltiplicazione in GF(2^8) con polinomio riduttore 0x11B.
 * Combinatorio puro, istanziato 4 volte in parallelo in aes_core.
 */
module aes_mixcolumn (
    input  wire [31:0] col_in,
    output wire [31:0] col_out
);
    wire [7:0] b0 = col_in[7:0];
    wire [7:0] b1 = col_in[15:8];
    wire [7:0] b2 = col_in[23:16];
    wire [7:0] b3 = col_in[31:24];

    wire [7:0] m2_b0 = {b0[6:0], 1'b0} ^ (b0[7] ? 8'h1b : 8'h00);
    wire [7:0] m2_b1 = {b1[6:0], 1'b0} ^ (b1[7] ? 8'h1b : 8'h00);
    wire [7:0] m2_b2 = {b2[6:0], 1'b0} ^ (b2[7] ? 8'h1b : 8'h00);
    wire [7:0] m2_b3 = {b3[6:0], 1'b0} ^ (b3[7] ? 8'h1b : 8'h00);

    assign col_out[31:24] = m2_b3 ^ (m2_b2 ^ b2) ^ b1 ^ b0;
    assign col_out[23:16] = b3 ^ m2_b2 ^ (m2_b1 ^ b1) ^ b0;
    assign col_out[15:8]  = b3 ^ b2 ^ m2_b1 ^ (m2_b0 ^ b0);
    assign col_out[7:0]   = (m2_b3 ^ b3) ^ b2 ^ b1 ^ m2_b0;
endmodule


/*
 * aes_sbox_bram — S-Box AES implementata su Block RAM Gowin
 *
 * ROM da 256 byte con lettura sincrona (1 ciclo di latenza).
 * L'attributo ram_style="block" forza il mapping su BSRAM anziché LUT.
 */
module aes_sbox_bram (
    input  wire       clk,
    input  wire [7:0] in_byte,
    output reg  [7:0] out_byte
);
    (* ram_style = "block" *)
    reg [7:0] rom [0:255];

    initial begin
        // riga 0
        rom[8'h00]=8'h63; rom[8'h01]=8'h7c; rom[8'h02]=8'h77; rom[8'h03]=8'h7b;
        rom[8'h04]=8'hf2; rom[8'h05]=8'h6b; rom[8'h06]=8'h6f; rom[8'h07]=8'hc5;
        rom[8'h08]=8'h30; rom[8'h09]=8'h01; rom[8'h0a]=8'h67; rom[8'h0b]=8'h2b;
        rom[8'h0c]=8'hfe; rom[8'h0d]=8'hd7; rom[8'h0e]=8'hab; rom[8'h0f]=8'h76;
        // riga 1
        rom[8'h10]=8'hca; rom[8'h11]=8'h82; rom[8'h12]=8'hc9; rom[8'h13]=8'h7d;
        rom[8'h14]=8'hfa; rom[8'h15]=8'h59; rom[8'h16]=8'h47; rom[8'h17]=8'hf0;
        rom[8'h18]=8'had; rom[8'h19]=8'hd4; rom[8'h1a]=8'ha2; rom[8'h1b]=8'haf;
        rom[8'h1c]=8'h9c; rom[8'h1d]=8'ha4; rom[8'h1e]=8'h72; rom[8'h1f]=8'hc0;
        // riga 2
        rom[8'h20]=8'hb7; rom[8'h21]=8'hfd; rom[8'h22]=8'h93; rom[8'h23]=8'h26;
        rom[8'h24]=8'h36; rom[8'h25]=8'h3f; rom[8'h26]=8'hf7; rom[8'h27]=8'hcc;
        rom[8'h28]=8'h34; rom[8'h29]=8'ha5; rom[8'h2a]=8'he5; rom[8'h2b]=8'hf1;
        rom[8'h2c]=8'h71; rom[8'h2d]=8'hd8; rom[8'h2e]=8'h31; rom[8'h2f]=8'h15;
        // riga 3
        rom[8'h30]=8'h04; rom[8'h31]=8'hc7; rom[8'h32]=8'h23; rom[8'h33]=8'hc3;
        rom[8'h34]=8'h18; rom[8'h35]=8'h96; rom[8'h36]=8'h05; rom[8'h37]=8'h9a;
        rom[8'h38]=8'h07; rom[8'h39]=8'h12; rom[8'h3a]=8'h80; rom[8'h3b]=8'he2;
        rom[8'h3c]=8'heb; rom[8'h3d]=8'h27; rom[8'h3e]=8'hb2; rom[8'h3f]=8'h75;
        // riga 4
        rom[8'h40]=8'h09; rom[8'h41]=8'h83; rom[8'h42]=8'h2c; rom[8'h43]=8'h1a;
        rom[8'h44]=8'h1b; rom[8'h45]=8'h6e; rom[8'h46]=8'h5a; rom[8'h47]=8'ha0;
        rom[8'h48]=8'h52; rom[8'h49]=8'h3b; rom[8'h4a]=8'hd6; rom[8'h4b]=8'hb3;
        rom[8'h4c]=8'h29; rom[8'h4d]=8'he3; rom[8'h4e]=8'h2f; rom[8'h4f]=8'h84;
        // riga 5
        rom[8'h50]=8'h53; rom[8'h51]=8'hd1; rom[8'h52]=8'h00; rom[8'h53]=8'hed;
        rom[8'h54]=8'h20; rom[8'h55]=8'hfc; rom[8'h56]=8'hb1; rom[8'h57]=8'h5b;
        rom[8'h58]=8'h6a; rom[8'h59]=8'hcb; rom[8'h5a]=8'hbe; rom[8'h5b]=8'h39;
        rom[8'h5c]=8'h4a; rom[8'h5d]=8'h4c; rom[8'h5e]=8'h58; rom[8'h5f]=8'hcf;
        // riga 6
        rom[8'h60]=8'hd0; rom[8'h61]=8'hef; rom[8'h62]=8'haa; rom[8'h63]=8'hfb;
        rom[8'h64]=8'h43; rom[8'h65]=8'h4d; rom[8'h66]=8'h33; rom[8'h67]=8'h85;
        rom[8'h68]=8'h45; rom[8'h69]=8'hf9; rom[8'h6a]=8'h02; rom[8'h6b]=8'h7f;
        rom[8'h6c]=8'h50; rom[8'h6d]=8'h3c; rom[8'h6e]=8'h9f; rom[8'h6f]=8'ha8;
        // riga 7
        rom[8'h70]=8'h51; rom[8'h71]=8'ha3; rom[8'h72]=8'h40; rom[8'h73]=8'h8f;
        rom[8'h74]=8'h92; rom[8'h75]=8'h9d; rom[8'h76]=8'h38; rom[8'h77]=8'hf5;
        rom[8'h78]=8'hbc; rom[8'h79]=8'hb6; rom[8'h7a]=8'hda; rom[8'h7b]=8'h21;
        rom[8'h7c]=8'h10; rom[8'h7d]=8'hff; rom[8'h7e]=8'hf3; rom[8'h7f]=8'hd2;
        // riga 8
        rom[8'h80]=8'hcd; rom[8'h81]=8'h0c; rom[8'h82]=8'h13; rom[8'h83]=8'hec;
        rom[8'h84]=8'h5f; rom[8'h85]=8'h97; rom[8'h86]=8'h44; rom[8'h87]=8'h17;
        rom[8'h88]=8'hc4; rom[8'h89]=8'ha7; rom[8'h8a]=8'h7e; rom[8'h8b]=8'h3d;
        rom[8'h8c]=8'h64; rom[8'h8d]=8'h5d; rom[8'h8e]=8'h19; rom[8'h8f]=8'h73;
        // riga 9
        rom[8'h90]=8'h60; rom[8'h91]=8'h81; rom[8'h92]=8'h4f; rom[8'h93]=8'hdc;
        rom[8'h94]=8'h22; rom[8'h95]=8'h2a; rom[8'h96]=8'h90; rom[8'h97]=8'h88;
        rom[8'h98]=8'h46; rom[8'h99]=8'hee; rom[8'h9a]=8'hb8; rom[8'h9b]=8'h14;
        rom[8'h9c]=8'hde; rom[8'h9d]=8'h5e; rom[8'h9e]=8'h0b; rom[8'h9f]=8'hdb;
        // riga A
        rom[8'ha0]=8'he0; rom[8'ha1]=8'h32; rom[8'ha2]=8'h3a; rom[8'ha3]=8'h0a;
        rom[8'ha4]=8'h49; rom[8'ha5]=8'h06; rom[8'ha6]=8'h24; rom[8'ha7]=8'h5c;
        rom[8'ha8]=8'hc2; rom[8'ha9]=8'hd3; rom[8'haa]=8'hac; rom[8'hab]=8'h62;
        rom[8'hac]=8'h91; rom[8'had]=8'h95; rom[8'hae]=8'he4; rom[8'haf]=8'h79;
        // riga B
        rom[8'hb0]=8'he7; rom[8'hb1]=8'hc8; rom[8'hb2]=8'h37; rom[8'hb3]=8'h6d;
        rom[8'hb4]=8'h8d; rom[8'hb5]=8'hd5; rom[8'hb6]=8'h4e; rom[8'hb7]=8'ha9;
        rom[8'hb8]=8'h6c; rom[8'hb9]=8'h56; rom[8'hba]=8'hf4; rom[8'hbb]=8'hea;
        rom[8'hbc]=8'h65; rom[8'hbd]=8'h7a; rom[8'hbe]=8'hae; rom[8'hbf]=8'h08;
        // riga C
        rom[8'hc0]=8'hba; rom[8'hc1]=8'h78; rom[8'hc2]=8'h25; rom[8'hc3]=8'h2e;
        rom[8'hc4]=8'h1c; rom[8'hc5]=8'ha6; rom[8'hc6]=8'hb4; rom[8'hc7]=8'hc6;
        rom[8'hc8]=8'he8; rom[8'hc9]=8'hdd; rom[8'hca]=8'h74; rom[8'hcb]=8'h1f;
        rom[8'hcc]=8'h4b; rom[8'hcd]=8'hbd; rom[8'hce]=8'h8b; rom[8'hcf]=8'h8a;
        // riga D
        rom[8'hd0]=8'h70; rom[8'hd1]=8'h3e; rom[8'hd2]=8'hb5; rom[8'hd3]=8'h66;
        rom[8'hd4]=8'h48; rom[8'hd5]=8'h03; rom[8'hd6]=8'hf6; rom[8'hd7]=8'h0e;
        rom[8'hd8]=8'h61; rom[8'hd9]=8'h35; rom[8'hda]=8'h57; rom[8'hdb]=8'hb9;
        rom[8'hdc]=8'h86; rom[8'hdd]=8'hc1; rom[8'hde]=8'h1d; rom[8'hdf]=8'h9e;
        // riga E
        rom[8'he0]=8'he1; rom[8'he1]=8'hf8; rom[8'he2]=8'h98; rom[8'he3]=8'h11;
        rom[8'he4]=8'h69; rom[8'he5]=8'hd9; rom[8'he6]=8'h8e; rom[8'he7]=8'h94;
        rom[8'he8]=8'h9b; rom[8'he9]=8'h1e; rom[8'hea]=8'h87; rom[8'heb]=8'he9;
        rom[8'hec]=8'hce; rom[8'hed]=8'h55; rom[8'hee]=8'h28; rom[8'hef]=8'hdf;
        // riga F
        rom[8'hf0]=8'h8c; rom[8'hf1]=8'ha1; rom[8'hf2]=8'h89; rom[8'hf3]=8'h0d;
        rom[8'hf4]=8'hbf; rom[8'hf5]=8'he6; rom[8'hf6]=8'h42; rom[8'hf7]=8'h68;
        rom[8'hf8]=8'h41; rom[8'hf9]=8'h99; rom[8'hfa]=8'h2d; rom[8'hfb]=8'h0f;
        rom[8'hfc]=8'hb0; rom[8'hfd]=8'h54; rom[8'hfe]=8'hbb; rom[8'hff]=8'h16;
    end

    // Lettura sincrona — 1 ciclo di latenza, necessario per il mapping su BSRAM
    always @(posedge clk) begin
        out_byte <= rom[in_byte];
    end
endmodule
