`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// sync_fifo.v  (Khushi)
//
// First-in first-out queue between the UART receiver and the packet parser.
// Bytes are pushed in as they arrive and popped out in the same order.
// It decouples the two sides: the receiver never has to wait for the parser.
//
// Write pointer and read pointer have ONE extra bit. When the low bits are
// equal the queue is either empty (extra bits equal) or full (extra bits
// different). That trick avoids needing a separate counter.
//
// 'dout' always shows the oldest byte (first-word fall-through), so the
// reader looks at dout while empty = 0 and pulses 'pop' to take it.
//////////////////////////////////////////////////////////////////////////////
module sync_fifo #(
    parameter WIDTH = 8,
    parameter AW    = 4             // depth = 2^AW = 16 entries
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             push,
    input  wire [WIDTH-1:0] din,
    input  wire             pop,
    output wire [WIDTH-1:0] dout,
    output wire             empty,
    output wire             full,
    output reg              overflow   // pulse: push while full (byte lost)
);
    reg [WIDTH-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wr_ptr, rd_ptr;

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);
    assign dout  = mem[rd_ptr[AW-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            overflow <= 1'b0;
        end else begin
            overflow <= push & full;
            if (push && !full) begin
                mem[wr_ptr[AW-1:0]] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end
endmodule
