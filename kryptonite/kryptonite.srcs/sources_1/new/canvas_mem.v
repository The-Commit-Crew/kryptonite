`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// canvas_mem.v  (Khushi)
//
// 96 x 64 drawing canvas, 1 bit per pixel (1 = ink, 0 = blank).
// 6144 bits in total, which fits in a single 18 Kb block RAM.
//
// Two ports so two parts of the design can use the canvas at the same time:
//   Port A : read + write. Used by the stroke engine (painting, erasing,
//            clearing) and by the downsampler (reading). Only one of them
//            drives it at a time (see vision_top.v).
//   Port B : read only. Used by the OLED renderer to show the canvas.
//
// Both reads are SYNCHRONOUS: you give an (x, y) on one clock edge and the
// pixel comes out after the NEXT clock edge (1 cycle latency). This is how
// block RAM works on the FPGA.
//
// Address mapping (row-major):  address = y * 96 + x
// 96 = 64 + 32, so y * 96 = (y << 6) + (y << 5). No multiplier needed.
//////////////////////////////////////////////////////////////////////////////
module canvas_mem (
    input  wire       clk,

    // Port A: read / write
    input  wire [6:0] a_x,      // 0..95
    input  wire [5:0] a_y,      // 0..63
    input  wire       a_we,     // 1 = write a_din into (a_x, a_y)
    input  wire       a_din,
    output reg        a_dout,   // pixel at (a_x, a_y) from the previous cycle

    // Port B: read only
    input  wire [6:0] b_x,
    input  wire [5:0] b_y,
    output reg        b_dout
);
    (* ram_style = "block" *) reg mem [0:6143];

    wire [12:0] a_addr = ({7'd0, a_y} << 6) + ({7'd0, a_y} << 5) + {6'd0, a_x};
    wire [12:0] b_addr = ({7'd0, b_y} << 6) + ({7'd0, b_y} << 5) + {6'd0, b_x};

    // Start with a blank canvas (Vivado uses this as the BRAM's initial value)
    integer i;
    initial begin
        for (i = 0; i < 6144; i = i + 1)
            mem[i] = 1'b0;
        a_dout = 1'b0;
        b_dout = 1'b0;
    end

    always @(posedge clk) begin
        if (a_we)
            mem[a_addr] <= a_din;
        a_dout <= mem[a_addr];
    end

    always @(posedge clk) begin
        b_dout <= mem[b_addr];
    end
endmodule
