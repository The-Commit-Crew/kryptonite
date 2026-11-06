`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06.11.2026 16:38:22
// Design Name: 
// Module Name: tb_decryption_ntt
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


module tb_decryption_ntt( );
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    wire done;
    wire [255:0] msg_bits;

    always #5 clk = ~clk;

    decryption_ntt dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(done),
        .msg_bits(msg_bits)
    );
    
    reg [0:0] msg_exp [0:255];
    initial $readmemh("msg_expected.mem", msg_exp);

    integer cycles = 0;
    reg [4:0] prev_state = 0;

    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            if (dut.state !== prev_state) begin
                case (dut.state)
                    5'd1: $display("  cycle %6d: loading u0 into NTT", cycles);
                    5'd3: $display("  cycle %6d: NTT(u0) start", cycles);
                    5'd5: $display("  cycle %6d: copying u0_hat to basemul", cycles);
                    5'd7: $display("  cycle %6d: loading u1 into NTT", cycles);
                    5'd9: $display("  cycle %6d: NTT(u1) start", cycles);
                    5'd11: $display("  cycle %6d: copying u1_hat to basemul", cycles);
                    5'd13: $display("  cycle %6d: basemul start", cycles);
                    5'd15: $display("  cycle %6d: copying product to INTT", cycles);
                    5'd17: $display("  cycle %6d: INTT start", cycles);
                    5'd19: $display("  cycle %6d: final subtract + threshold", cycles);
                    5'd21: $display("  cycle %6d: DONE", cycles);
                endcase
                prev_state = dut.state;
            end
        end
    end

    integer start_cycle, wait_cycles = 0;
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
        start_cycle = cycles;

        while (!done && wait_cycles < 50000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (!done) begin
            $display("TIMEOUT: done never went high (stuck in state %0d, k=%0d)", dut.state, dut.k);
            $finish;
        end
        $display("total: %0d cycles from start to done", cycles - start_cycle);

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
            else $write(".");
        end
        $display("\"");

        $display("bit mismatches: %0d", bit_errors);
        if (bit_errors == 0)
            $display("PASS: NTT decryption matches Python");
        else
            $display("FAIL");

        $finish;
    end

endmodule
