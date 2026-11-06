`timescale 1ns / 1ps

// Multiply in Z_3329[X]/(X^256 + 1). Load all 256 coefficient pairs while
// idle, pulse start, then wait for the one-cycle done pulse. Inputs and outputs
// are canonical normal-form coefficients (0..3328); rd_data is synchronous.
// Reload both operands before each start: the forward NTTs operate in place.
module shared_poly_multiplier #(
    parameter ZETAS_FILE = "zetas.mem",
    parameter GAMMAS_FILE = "gammas.mem"
)(
    input wire clk, rst,
    input wire wr_en,
    input wire [7:0] wr_addr,
    input wire [11:0] left_data, right_data,
    input wire start,
    output reg done,
    input wire [7:0] rd_addr,
    output wire [11:0] rd_data
);
    localparam [4:0] IDLE = 0, NTT_GO = 1, NTT_WAIT = 2,
                     READ_EVEN = 3, SAVE_EVEN = 4,
                     READ_ODD = 5, SAVE_ODD = 6,
                     MUL_WAIT = 7,
                     WRITE_EVEN = 12, WRITE_ODD = 13,
                     INTT_GO = 14, INTT_WAIT = 15;
    reg [4:0] state;
    reg [6:0] pair_index;
    reg [2:0] operation, pipeline_left;
    reg [11:0] a0, a1, b0, b1;
    reg [11:0] r00, r11, r11g, r01, r10;
    reg [11:0] gammas [0:127];
    reg [11:0] gamma_q;

    initial $readmemh(GAMMAS_FILE, gammas);
    always @(posedge clk)
        gamma_q <= gammas[pair_index];

    wire odd_read = (state == READ_ODD || state == SAVE_ODD);
    wire [7:0] ntt_addr = (state == IDLE) ? wr_addr : {pair_index, odd_read};
    wire ntt_we = (state == IDLE) && wr_en && !rst;
    wire ntt_go = (state == NTT_GO);
    wire left_done, right_done;
    wire [11:0] left_hat, right_hat;

    // Both operands are writable. No secret-key ROM or decryption dot product
    // is involved; the two forward transforms run concurrently.
    ntt_core #(.ZETAS_FILE(ZETAS_FILE), .PIPELINED(1)) left_ntt (
        .clk(clk), .rst(rst), .go(ntt_go), .done(left_done),
        .ext_we(ntt_we), .ext_addr(ntt_addr),
        .ext_wdata(left_data), .ext_rdata(left_hat)
    );
    ntt_core #(.ZETAS_FILE(ZETAS_FILE), .PIPELINED(1)) right_ntt (
        .clk(clk), .rst(rst), .go(ntt_go), .done(right_done),
        .ext_we(ntt_we), .ext_addr(ntt_addr),
        .ext_wdata(right_data), .ext_rdata(right_hat)
    );

    // Each adjacent NTT pair represents a polynomial modulo X^2 - gamma:
    // c0 = a0*b0 + gamma*a1*b1, c1 = a0*b1 + a1*b0 (all modulo q).
    // Share one variable multiplier and Barrett reducer across the five terms.
    reg [11:0] factor_a, factor_b;
    always @(*) begin
        factor_a = a0;
        factor_b = b0;
        case (operation)
            1: begin factor_a = a1; factor_b = b1; end
            2: begin factor_a = r11; factor_b = gamma_q; end
            3: begin factor_a = a0; factor_b = b1; end
            4: begin factor_a = a1; factor_b = b0; end
            default: begin end
        endcase
    end
    wire [11:0] reduced;
    mod_mult_pipeline reduce_product (.clk(clk), .a(factor_a), .b(factor_b), .r(reduced));

    function [11:0] add_mod_q;
        input [11:0] a, b;
        reg [12:0] sum;
        begin
            sum = {1'b0, a} + {1'b0, b};
            add_mod_q = (sum >= 13'd3329) ? sum - 13'd3329 : sum;
        end
    endfunction

    wire intt_we = (state == WRITE_EVEN || state == WRITE_ODD) && !rst;
    wire [7:0] intt_addr = (state == IDLE) ? rd_addr
                              : {pair_index, (state == WRITE_ODD)};
    wire [11:0] intt_data = (state == WRITE_ODD) ? add_mod_q(r01, r10)
                                                               : add_mod_q(r00, r11g);
    wire intt_done;
    intt_core #(.ZETAS_FILE(ZETAS_FILE), .PIPELINED(1)) inverse_ntt (
        .clk(clk), .rst(rst), .go(state == INTT_GO), .done(intt_done),
        .ext_we(intt_we), .ext_addr(intt_addr),
        .ext_wdata(intt_data), .ext_rdata(rd_data)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            pair_index <= 0;
            operation <= 0;
            pipeline_left <= 0;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    pair_index <= 0;
                    state <= NTT_GO;
                end
                NTT_GO: state <= NTT_WAIT;
                NTT_WAIT: if (left_done && right_done) state <= READ_EVEN;
                READ_EVEN: state <= SAVE_EVEN;
                SAVE_EVEN: begin
                    a0 <= left_hat;
                    b0 <= right_hat;
                    state <= READ_ODD;
                end
                READ_ODD: state <= SAVE_ODD;
                SAVE_ODD: begin
                    a1 <= left_hat;
                    b1 <= right_hat;
                    operation <= 0;
                    pipeline_left <= 5;
                    state <= MUL_WAIT;
                end
                MUL_WAIT: if (pipeline_left != 0) begin
                    pipeline_left <= pipeline_left - 1'b1;
                end else begin
                    case (operation)
                        0: r00 <= reduced;
                        1: r11 <= reduced;
                        2: r11g <= reduced;
                        3: r01 <= reduced;
                        4: r10 <= reduced;
                    endcase
                    operation <= operation + 1'b1;
                    pipeline_left <= 5;
                    if (operation == 4) state <= WRITE_EVEN;
                end
                WRITE_EVEN: state <= WRITE_ODD;
                WRITE_ODD: begin
                    pair_index <= pair_index + 7'd1;
                    state <= (pair_index == 7'd127) ? INTT_GO : READ_EVEN;
                end
                INTT_GO: state <= INTT_WAIT;
                INTT_WAIT: if (intt_done) begin
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
