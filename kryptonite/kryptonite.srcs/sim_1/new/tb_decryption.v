`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 08:49:37
// Design Name: 
// Module Name: tb_decryption
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


module tb_decryption( );
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    wire done;
    wire [255:0] msg_bits;
    always #5 clk = ~clk;
    decryption_core dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(done),
        .msg_bits(msg_bits)
    );

    reg [11:0] w_exp   [0:255];
    reg [0:0]  msg_exp [0:255];

    initial begin
        $readmemh("w_expected.mem",   w_exp);
        $readmemh("msg_expected.mem", msg_exp);
    end

    integer w_errors = 0;

    always @(posedge clk) begin
        if (!rst && dut.state == 4'd8) begin
            if (dut.w !== w_exp[dut.k]) begin
                w_errors = w_errors + 1;
                if (w_errors <= 10)
                    $display("W MISMATCH  k=%0d  got=%0d  expected=%0d  (acc=%0d, v=%0d)",
                             dut.k, dut.w, w_exp[dut.k], dut.acc, dut.v_q);
            end
            if (dut.k % 32 == 0)
                $display("  progress: k=%0d  at %0t ns", dut.k, $time);
        end
    end

    integer cycles = 0;
    integer bit_errors = 0;
    integer n, b;
    reg [7:0] ch;

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        start = 1;
        @(posedge clk);
        start = 0;

        while (!done && cycles < 2000000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("TIMEOUT: done never went high after %0d cycles", cycles);
            $finish;
        end
        $display("done after %0d cycles (%0t ns)", cycles, $time);

        for (n = 0; n < 256; n = n + 1) begin
            if (msg_bits[n] !== msg_exp[n]) begin
                bit_errors = bit_errors + 1;
                if (bit_errors <= 10)
                    $display("BIT MISMATCH  index=%0d  got=%0b  expected=%0b",
                             n, msg_bits[n], msg_exp[n]);
            end
        end

        $write("decrypted text: \"");
        for (n = 0; n < 32; n = n + 1) begin
            for (b = 0; b < 8; b = b + 1)
                ch[b] = msg_bits[8*n + b];
            if (ch >= 8'h20 && ch <= 8'h7E) $write("%c", ch);
            else                             $write(".");
        end
        $display("\"");

        $display("w mismatches:   %0d", w_errors);
        $display("bit mismatches: %0d", bit_errors);
        if (w_errors == 0 && bit_errors == 0)
            $display("PASS: decryption matches Python");
        else
            $display("FAIL");

        $finish;
    end

endmodule
