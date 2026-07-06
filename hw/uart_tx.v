/*
 * uart_tx.v — Trasmettitore UART, formato 8N1
 *
 * Parametro CLKS_PER_BIT: cicli di clock per bit (es. 27MHz/115200 = 234).
 * Alza i_valid per un ciclo con i_data valido per avviare la trasmissione.
 * Non inviare un nuovo byte finché o_busy è alto.
 */

module uart_tx #(
    parameter CLKS_PER_BIT = 234
)(
    input  wire       clk,
    input  wire       resetn,
    input  wire [7:0] i_data,
    input  wire       i_valid,
    output reg        o_busy,
    output reg        o_tx
);
    localparam IDLE  = 2'd0;
    localparam START = 2'd1;
    localparam DATA  = 2'd2;
    localparam STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;
    reg [8:0] clk_cnt;

    always @(posedge clk) begin
        if (!resetn) begin
            state     <= IDLE;
            o_tx      <= 1'b1;
            o_busy    <= 1'b0;
            clk_cnt   <= 0;
            bit_cnt   <= 0;
            shift_reg <= 0;
        end else begin
            case (state)
                IDLE: begin
                    o_tx   <= 1'b1;
                    o_busy <= 1'b0;
                    if (i_valid) begin
                        shift_reg <= i_data;
                        clk_cnt   <= 0;
                        o_busy    <= 1'b1;
                        state     <= START;
                    end
                end

                START: begin
                    o_tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        bit_cnt <= 0;
                        state   <= DATA;
                    end else
                        clk_cnt <= clk_cnt + 1;
                end

                DATA: begin
                    o_tx <= shift_reg[0];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt   <= 0;
                        shift_reg <= shift_reg >> 1;
                        if (bit_cnt == 7)
                            state <= STOP;
                        else
                            bit_cnt <= bit_cnt + 1;
                    end else
                        clk_cnt <= clk_cnt + 1;
                end

                STOP: begin
                    o_tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state   <= IDLE;
                        o_busy  <= 1'b0;
                    end else
                        clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule
