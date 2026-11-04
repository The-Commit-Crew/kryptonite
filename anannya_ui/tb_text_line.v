`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 06:38:25 PM
// Design Name: 
// Module Name: tb_text_line
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


module tb_text_line;
    reg  [6:0] px;
    reg  [5:0] py;
    wire on1, on2, on3;
    integer errors = 0;

    text_line #(.N(1), .X0(10), .Y0(5), .SCALE(1)) d1 (.px(px), .py(py), .chars("0"),  .on(on1));
    text_line #(.N(1), .X0(0),  .Y0(0), .SCALE(2)) d2 (.px(px), .py(py), .chars("0"),  .on(on2));
    text_line #(.N(2), .X0(0),  .Y0(0), .SCALE(1)) d3 (.px(px), .py(py), .chars("01"), .on(on3));

    task c1; input [6:0] x; input [5:0] y; input want;
        begin px = x; py = y; #1;
            if (on1 !== want) begin errors = errors + 1; $display("FAIL d1 (%0d,%0d) got %b want %b", x, y, on1, want); end
        end
    endtask
    task c2; input [6:0] x; input [5:0] y; input want;
        begin px = x; py = y; #1;
            if (on2 !== want) begin errors = errors + 1; $display("FAIL d2 (%0d,%0d) got %b want %b", x, y, on2, want); end
        end
    endtask
    task c3; input [6:0] x; input [5:0] y; input want;
        begin px = x; py = y; #1;
            if (on3 !== want) begin errors = errors + 1; $display("FAIL d3 (%0d,%0d) got %b want %b", x, y, on3, want); end
        end
    endtask

    initial begin
        // '0' at (10,5), scale 1. Rows: 01110 10001 10011 10101 11001 10001 01110
        c1(11, 5, 1); c1(10, 5, 0); c1(10, 6, 1); c1(14, 6, 1);
        c1(15, 6, 0);                    // gap column
        c1(12, 8, 1); c1(11, 8, 0);      // row 3 = 10101
        c1(9, 5, 0);                     // left of the box
        c1(11, 12, 0);                   // below the box
        // '0' at scale 2
        c2(2, 0, 1); c2(3, 0, 1); c2(1, 0, 0); c2(2, 1, 1);
        c2(0, 2, 1); c2(0, 3, 1); c2(2, 2, 0);
        c2(10, 0, 0);                    // gap column
        c2(0, 14, 0);                    // below the box
        // "01": second char is '1' (row 0 = 00100) starting at x = 6
        c3(8, 0, 1); c3(7, 0, 0); c3(1, 0, 1); c3(12, 0, 0);

        if (errors == 0) $display("PASS: text_line");
        else             $display("FAIL: text_line, %0d errors", errors);
        $finish;
    end
endmodule
