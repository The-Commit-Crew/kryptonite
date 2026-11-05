`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 22:06:02
// Design Name: 
// Module Name: butterfly_inv
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


module butterfly_inv( input [11:0] a, b, zeta, output [11:0] a_out, b_out );
    wire [12:0] sub_tmp = b + 3329 - a;
    wire [11:0] diff = (sub_tmp >= 3329)? sub_tmp - 3329: sub_tmp;
    wire [23:0] prod = zeta * diff;
    barrett_reduce red(.x(prod), .r(b_out));
    wire [12:0] add_tmp = a + b;
    assign a_out = (add_tmp >= 3329)? add_tmp - 3329:add_tmp;
endmodule
