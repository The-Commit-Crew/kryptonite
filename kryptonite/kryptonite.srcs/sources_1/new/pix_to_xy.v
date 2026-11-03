`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// pix_to_xy.v  (Khushi) - turn the OLED's pixel_index into (x, y)
//
// pixel_index = y * 96 + x, so  y = index / 96  and  x = index - y * 96.
// Writing "/ 96" and "% 96" in Verilog builds a whole divider circuit.
// Instead we multiply by a fixed-point reciprocal:
//      index / 96  =  (index * 2731) >> 18      (2731 / 2^18 ~= 1/96)
// Exact for every index 0..6143 (checked in Python). Then
//      x = index - (y << 6) - (y << 5)          (y*96 = y*64 + y*32)
// Anannya can use this module in the UI renderer too.
//////////////////////////////////////////////////////////////////////////////
module pix_to_xy (
    input  wire [12:0] pix,
    output wire [6:0]  x,
    output wire [5:0]  y
);
    wire [25:0] prod = pix * 13'd2731;
    assign y = prod[23:18];
    wire [12:0] y96 = ({7'd0, y} << 6) + ({7'd0, y} << 5);
    wire [12:0] xf  = pix - y96;
    assign x = xf[6:0];
endmodule
