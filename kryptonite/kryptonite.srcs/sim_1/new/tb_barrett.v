`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.11.2026 16:50:41
// Design Name: 
// Module Name: tb_barrett
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


module tb_barrett( );
    reg  [23:0] x;
    wire [11:0] r;
    barrett_reduce dut (.x(x), .r(r));
    
    integer i, a, b;
    integer expected;
    integer errors = 0;
    
    task check(input [23:0] val);
        begin
            x = val; #1;
            expected = val % 3329;
            if (r !== expected) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH: x=%0d  got=%0d  expected=%0d", val, r, expected);
            end
        end
    endtask

    initial begin
        check(0);
        check(3328);
        check(3329);
        check(3328 * 3328);
        check(3329 * 3328);
        for (i = 0; i < 10000; i = i + 1) begin
            a = $urandom % 3329;
            b = $urandom % 3329;
            check(a * b);
        end
        if (errors == 0)
            $display("PASS: all tests matched");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end
endmodule
