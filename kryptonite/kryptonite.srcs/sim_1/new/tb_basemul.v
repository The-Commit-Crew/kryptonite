`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06.11.2026 14:55:53
// Design Name: 
// Module Name: tb_basemul
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


module tb_basemul( );
    reg clk = 0, rst = 1, go = 0;
    wire done;

    always #5 clk = ~clk;

    basemul_core #(.INIT_U0("u0_hat.mem"), .INIT_U1("u1_hat.mem")) dut (
    .clk(clk), .rst(rst), .go(go), .done(done),
    .ext_we(1'b0), .ext_sel(1'b0), .ext_addr(8'd0), .ext_wdata(12'd0), .ext_rdata()
);

    reg [11:0] exp [0:255];
    initial $readmemh("prod_hat.mem", exp);

    integer cycles = 0;
    integer x, bad = 0;

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        go = 1;
        @(posedge clk); #1;
        go = 0;

        while (!done && cycles < 100000) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("TIMEOUT after %0d cycles (state=%0d i=%0d p=%0d)",
                     cycles, dut.state, dut.i, dut.p);
            $finish;
        end

        for (x = 0; x < 256; x = x + 1) begin
            if (dut.prod[x] !== exp[x]) begin
                bad = bad + 1;
                if (bad <= 10)
                    $display("MISMATCH index=%0d (pair %0d, %s)  got=%0d  expected=%0d",
                             x, x / 2, (x % 2 == 0) ? "c0" : "c1", dut.prod[x], exp[x]);
            end
        end

        $display("done after %0d cycles", cycles);
        if (bad == 0)
            $display("PASS: basemul output matches prod_hat.mem");
        else
            $display("FAIL: %0d mismatches", bad);
        $finish;
    end

endmodule
