`timescale 1ns / 1ps

// Demo noise source. Pulse start while idle with the debounced Send event.
// After done, the encryption controller can read r0, r1, e1_0, e1_1, e2.
module noise_sampler (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         busy,
    output reg         done,

    // Synchronous read, with rd_poly in 0..4 and one cycle of latency.
    input  wire [2:0]  rd_poly,
    input  wire [7:0]  rd_addr,
    output reg  [11:0] rd_data
);
    reg [63:0] counter;
    reg [63:0] lfsr;
    reg [4:0] warmup_left;
    reg [10:0] write_addr;
    reg [11:0] coefficients [0:1279];

    // XOR Fibonacci LFSR using the 64, 63, 61, 60 taps from AMD XAPP052.
    function [63:0] advance;
        input [63:0] state;
        begin
            advance = {state[62:0], state[63] ^ state[62] ^ state[60] ^ state[59]};
        end
    endfunction

    function [1:0] popcount3;
        input [2:0] bits;
        begin
            popcount3 = {1'b0, bits[0]} + {1'b0, bits[1]} + {1'b0, bits[2]};
        end
    endfunction

    wire [63:0] after_four = advance(advance(advance(advance(lfsr))));
    wire [63:0] after_six = advance(advance(after_four));
    wire eta3 = write_addr < 11'd512;
    wire [1:0] positive = popcount3(eta3 ? lfsr[63:61] : {1'b0, lfsr[63:62]});
    wire [1:0] negative = popcount3(eta3 ? lfsr[60:58] : {1'b0, lfsr[61:60]});
    wire [11:0] positive_wide = {10'd0, positive};
    wire [11:0] negative_wide = {10'd0, negative};
    wire [11:0] sample = (positive >= negative)
                       ? positive_wide - negative_wide
                       : 12'd3329 + positive_wide - negative_wide;

    always @(posedge clk) begin
        rd_data <= coefficients[{rd_poly, rd_addr}];
        if (rst) begin
            counter <= 0;
            busy <= 0;
            done <= 0;
        end else begin
            counter <= counter + 64'd1;
            done <= 0;
            if (busy) begin
                if (warmup_left != 0) begin
                    lfsr <= after_four;
                    warmup_left <= warmup_left - 5'd1;
                end else begin
                    coefficients[write_addr] <= sample;
                    lfsr <= eta3 ? after_six : after_four;
                    if (write_addr == 11'd1279) begin
                        busy <= 0;
                        done <= 1;
                    end else begin
                        write_addr <= write_addr + 11'd1;
                    end
                end
            end else if (start) begin
                lfsr <= (counter == 0) ? 64'd1 : counter;
                // Advance by 64 bits before sampling so high counter bits
                // don't become the initial samples directly.
                warmup_left <= 5'd16;
                write_addr <= 0;
                busy <= 1;
            end
        end
    end
endmodule
