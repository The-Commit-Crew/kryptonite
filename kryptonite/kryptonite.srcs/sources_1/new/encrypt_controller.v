`timescale 1ns / 1ps

module encrypt_controller (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [255:0] message,      // Byte 0 is in bits [7:0].
    output wire         busy,
    output reg          done,

    // Source memories return data one clock after the address is presented.
    // Key order: A00, A01, A10, A11, t0, t1. Noise: r0, r1, e1_0, e1_1, e2.
    output reg  [2:0]   key_poly,
    output wire [2:0]   noise_poly,
    output wire [7:0]   source_addr,
    input  wire [11:0]  key_data,
    input  wire [11:0]  noise_data,

    // Load both operands together, then pulse mul_start. Read the normal-form
    // product one clock after presenting mul_rd_addr, once mul_done pulses.
    output wire         mul_wr_en,
    output wire [7:0]   mul_wr_addr,
    output wire [11:0]  mul_left,
    output wire [11:0]  mul_right,
    output wire         mul_start,
    input  wire         mul_done,
    output wire [7:0]   mul_rd_addr,
    input  wire [11:0]  mul_rd_data,

    // Read after done. Addresses 0..767 are u0, u1, v, with one-clock latency.
    input  wire [9:0]   ciphertext_addr,
    output reg  [11:0]  ciphertext_data
);
    localparam [2:0] IDLE = 0, READ_OPERANDS = 1, WRITE_OPERANDS = 2,
                     START_MUL = 3, WAIT_MUL = 4, READ_RESULT = 5, SAVE_RESULT = 6;

    reg [2:0] state;
    reg [2:0] product;
    reg [7:0] coefficient;
    reg [255:0] message_latched;
    reg [11:0] partial [0:255];
    reg [11:0] partial_data;
    reg [11:0] ciphertext [0:767];

    function [11:0] add_mod_q;
        input [11:0] a, b;
        reg [12:0] sum;
        begin
            sum = {1'b0, a} + {1'b0, b};
            if (sum >= 13'd3329)
                sum = sum - 13'd3329;
            add_mod_q = sum[11:0];
        end
    endfunction

    // Select A by columns for A^T*r, then select t for the final dot product.
    always @(*) begin
        case (product)
            3'd1: key_poly = 3'd2;
            3'd2: key_poly = 3'd1;
            default: key_poly = product;
        endcase
    end

    assign busy = (state != IDLE);
    assign source_addr = coefficient;
    assign noise_poly = (state == READ_OPERANDS || state == WRITE_OPERANDS)
                      ? {2'b00, product[0]} : (3'd2 + {1'b0, product[2:1]});
    assign mul_wr_en = (state == WRITE_OPERANDS);
    assign mul_wr_addr = coefficient;
    assign mul_left = key_data;
    assign mul_right = noise_data;
    assign mul_start = (state == START_MUL);
    assign mul_rd_addr = coefficient;

    wire [11:0] pair_sum = add_mod_q(partial_data, mul_rd_data);
    wire [11:0] message_term = message_latched[coefficient] ? 12'd1665 : 12'd0;

    always @(posedge clk) begin
        ciphertext_data <= ciphertext[ciphertext_addr];
        if (state == READ_RESULT)
            partial_data <= partial[coefficient];

        if (rst) begin
            state <= IDLE;
            product <= 0;
            coefficient <= 0;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    message_latched <= message;
                    product <= 0;
                    coefficient <= 0;
                    state <= READ_OPERANDS;
                end
                READ_OPERANDS: state <= WRITE_OPERANDS;
                WRITE_OPERANDS: begin
                    coefficient <= coefficient + 8'd1;
                    state <= (coefficient == 8'd255) ? START_MUL : READ_OPERANDS;
                end
                START_MUL: state <= WAIT_MUL;
                WAIT_MUL: if (mul_done)
                    state <= READ_RESULT;
                READ_RESULT: state <= SAVE_RESULT;
                SAVE_RESULT: begin
                    if (!product[0])
                        partial[coefficient] <= add_mod_q(mul_rd_data, noise_data);
                    else
                        ciphertext[{product[2:1], coefficient}] <=
                            (product == 3'd5) ? add_mod_q(pair_sum, message_term) : pair_sum;

                    coefficient <= coefficient + 8'd1;
                    if (coefficient != 8'd255) begin
                        state <= READ_RESULT;
                    end else if (product == 3'd5) begin
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        product <= product + 3'd1;
                        state <= READ_OPERANDS;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
