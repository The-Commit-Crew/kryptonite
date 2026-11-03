`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// seg7_stats.v  (Khushi)
//
// Shows one link counter on the 4-digit 7-segment display:
//      [letter][hundreds][tens][ones]
//   mode 0:  S 012   data packets sent and acknowledged
//   mode 1:  r 011   new data packets received
//   mode 2:  E 001   errors detected (bad checksum, timeout, ...)
//   mode 3:  n 001   re-sends (after a NAK or a missing ACK)
// A pulse on 'next' moves to the next mode.
//
// The 4 digits share the same segment wires, so we light ONE digit at a
// time and switch quickly (about 380 Hz per digit). Your eye sees all four.
// Basys3 segments and anodes are active LOW (0 = on).
//////////////////////////////////////////////////////////////////////////////
module seg7_stats (
    input  wire        clk,
    input  wire        rst,
    input  wire        next,         // pulse (debounced button)
    input  wire [11:0] cnt_sent,     // 3 BCD digits each
    input  wire [11:0] cnt_recv,
    input  wire [11:0] cnt_err,
    input  wire [11:0] cnt_retry,
    output reg  [6:0]  seg,          // {g,f,e,d,c,b,a}, active low
    output reg  [3:0]  an,           // active low
    output wire        dp
);
    assign dp = 1'b1;                // decimal point off

    reg [1:0] mode;
    always @(posedge clk) begin
        if (rst)       mode <= 2'd0;
        else if (next) mode <= mode + 2'd1;
    end

    reg [11:0] val;
    reg [6:0]  letter;
    always @(*) begin
        case (mode)
            2'd0: begin val = cnt_sent;  letter = 7'b0010010; end // S
            2'd1: begin val = cnt_recv;  letter = 7'b0101111; end // r
            2'd2: begin val = cnt_err;   letter = 7'b0000110; end // E
            default: begin val = cnt_retry; letter = 7'b0101011; end // n
        endcase
    end

    function [6:0] digit;
        input [3:0] d;
        case (d)
            4'd0: digit = 7'b1000000;
            4'd1: digit = 7'b1111001;
            4'd2: digit = 7'b0100100;
            4'd3: digit = 7'b0110000;
            4'd4: digit = 7'b0011001;
            4'd5: digit = 7'b0010010;
            4'd6: digit = 7'b0000010;
            4'd7: digit = 7'b1111000;
            4'd8: digit = 7'b0000000;
            4'd9: digit = 7'b0010000;
            default: digit = 7'b0111111;   // dash
        endcase
    endfunction

    reg [17:0] refresh;
    always @(posedge clk) begin
        if (rst) refresh <= 0;
        else     refresh <= refresh + 18'd1;
    end

    always @(*) begin
        case (refresh[17:16])
            2'd0: begin an = 4'b0111; seg = letter;           end // leftmost
            2'd1: begin an = 4'b1011; seg = digit(val[11:8]); end
            2'd2: begin an = 4'b1101; seg = digit(val[7:4]);  end
            default: begin an = 4'b1110; seg = digit(val[3:0]); end
        endcase
    end
endmodule
