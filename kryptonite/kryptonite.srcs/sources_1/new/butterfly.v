`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 18:00:39
// Design Name: 
// Module Name: butterfly
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


module butterfly( input [11:0] a, b, zeta, output [11:0] a_out, b_out );
    wire [23:0] prod = zeta * b;
    wire [11:0] t;
    barrett_reduce red(.x(prod), .r(t));
    wire [12:0] add_tmp = a + t;
    assign a_out = (add_tmp >= 3329)? add_tmp - 3329:add_tmp;
    wire [12:0] sub_tmp = a + 3329 - t;
    assign b_out = (sub_tmp >= 3329)? sub_tmp - 3329: sub_tmp;
endmodule
