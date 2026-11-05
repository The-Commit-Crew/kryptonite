`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.11.2026 13:25:05
// Design Name: 
// Module Name: barrett_reduce
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


module barrett_reduce(
    input [23:0] x,
    output [11:0] r
    );
    wire [12:0] quotient = (x * 37'd5039) >> 24;
    wire [12:0] r0 = x - (quotient * 3329);
    assign r = (r0 >= 3329)? r0 - 3329 : r0;
endmodule
