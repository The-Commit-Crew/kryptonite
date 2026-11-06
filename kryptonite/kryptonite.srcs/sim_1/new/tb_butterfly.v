`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 18:19:48
// Design Name: 
// Module Name: tb_butterfly
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


module tb_butterfly( );

    reg  [11:0] a, b, zeta;
    wire [11:0] a_out, b_out;

    butterfly dut (.a(a), .b(b), .zeta(zeta), .a_out(a_out), .b_out(b_out));

    integer i;
    integer t, exp_a, exp_b;
    integer errors = 0;

    task check(input [11:0] va, vb, vz);
        begin
            a = va; b = vb; zeta = vz;
            #1;
            t = (vz * vb) % 3329;
            exp_a = (va + t) % 3329;
            exp_b = (va + 3329 - t) % 3329;
            if (a_out !== exp_a || b_out !== exp_b) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH a=%0d b=%0d zeta=%0d | got a_out=%0d b_out=%0d | expected %0d %0d",
                             va, vb, vz, a_out, b_out, exp_a, exp_b);
            end
        end
    endtask

    initial begin
        check(0, 0, 0);
        check(3328, 3328, 3328);
        check(0, 3328, 3328);
        check(3328, 1, 1);
        check(5, 3, 1729);
        check(1, 3, 1729);
        check(2, 4, 1729);

        for (i = 0; i < 10000; i = i + 1)
            check($urandom % 3329, $urandom % 3329, $urandom % 3329);

        if (errors == 0)
            $display("PASS: all butterfly tests matched");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
