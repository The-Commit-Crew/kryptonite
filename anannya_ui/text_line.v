`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 06:12:53 PM
// Design Name: 
// Module Name: text_line
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module text_line #(
    parameter N = 1,       // number of characters
    parameter X0 = 0,      // top-left corner on screen
    parameter Y0 = 0,
    parameter SCALE = 1    // 1 = 5x7 pixels, 2 = 10x14, ...
)(
    input  wire [6:0]     px,
    input  wire [5:0]     py,
    input  wire [N*8-1:0] chars,    // first character in the top byte
    output wire           on
    );
    
    localparam PITCH = 6 * SCALE;   // 5 pixel glyph + 1 pixel gap, scaled
    localparam W     = N * PITCH;
    localparam H     = 7 * SCALE;

    wire in_box = (px >= X0) && (px < X0 + W) && (py >= Y0) && (py < Y0 + H);

    wire [6:0] dx     = px - X0;
    wire [5:0] dy     = py - Y0;
    wire [6:0] ci     = dx / PITCH;                 // which character
    wire [6:0] ci_c   = (ci < N) ? ci : 7'd0;       // keep the index in range
    wire [6:0] within = dx - ci * PITCH;            // pixel offset inside the cell
    wire [6:0] col    = within / SCALE;             // glyph column 0..5 (5 = gap)
    wire [5:0] row    = dy / SCALE;                 // glyph row 0..6
    wire [2:0] colc   = (col < 5) ? col[2:0] : 3'd0;

    wire [7:0] ch = chars[(N - 1 - ci_c) * 8 +: 8];
    wire [4:0] bits;
    font_rom u_font (.ascii(ch), .row(row[2:0]), .bits(bits));

    assign on = in_box && (col < 5) && bits[4 - colc];
endmodule
