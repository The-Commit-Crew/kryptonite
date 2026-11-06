`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06.11.2026 14:49:03
// Design Name: 
// Module Name: tb_intt
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


module tb_intt( );
    reg clk = 0, rst = 1, go = 0;
    wire done;

    always #5 clk = ~clk;

    intt_core #(.INIT_FILE("prod_hat.mem")) dut (.clk(clk), .rst(rst), .go(go), .done(done));

    reg [11:0] exp [0:8*256-1];
    initial begin
        $readmemh("intt_layer1.mem", exp, 0, 255);
        $readmemh("intt_layer2.mem", exp, 256, 511);
        $readmemh("intt_layer3.mem", exp, 512, 767);
        $readmemh("intt_layer4.mem", exp, 768, 1023);
        $readmemh("intt_layer5.mem", exp, 1024, 1279);
        $readmemh("intt_layer6.mem", exp, 1280, 1535);
        $readmemh("intt_layer7.mem", exp, 1536, 1791);
        $readmemh("intt_out.mem", exp, 1792, 2047);
    end

    integer x, bad, total_bad = 0;

    task check_block(input integer L);
        begin
            bad = 0;
            for (x = 0; x < 256; x = x + 1) begin
                if (dut.f[x] !== exp[(L-1)*256 + x]) begin
                    if (bad == 0)
                        $display("%s %0d WRONG: first bad index %0d  got=%0d  expected=%0d",
                                 (L == 8) ? "output" : "layer", L, x, dut.f[x], exp[(L-1)*256 + x]);
                    bad = bad + 1;
                end
            end
            if (L == 8) begin
                if (bad == 0) $display("scaled output OK");
                else $display("scaled output: %0d wrong coefficients", bad);
            end else begin
                if (bad == 0) $display("layer %0d OK", L);
                else $display("layer %0d: %0d wrong coefficients", L, bad);
            end
            total_bad = total_bad + bad;
        end
    endtask

    localparam SCALE_READ = 4'd5;

    integer cycles = 0;
    integer layer = 0;
    reg [7:0] prev_len;
    reg scaling_seen = 0;

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        go = 1;
        @(posedge clk); #1;
        go = 0;
        prev_len = dut.len;

        while (!done && cycles < 100000) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
            if (dut.len !== prev_len) begin
                layer = layer + 1;
                check_block(layer);
                prev_len = dut.len;
            end
            if (!scaling_seen && dut.state == SCALE_READ) begin
                scaling_seen = 1;
                layer = layer + 1;
                check_block(layer);
            end
        end

        if (!done) begin
            $display("TIMEOUT after %0d cycles (state=%0d len=%0d start=%0d j=%0d zk=%0d)",
                     cycles, dut.state, dut.len, dut.start, dut.j, dut.zk);
            $finish;
        end

        check_block(8);

        $display("done after %0d cycles, final zk = %0d (should be 1)", cycles, dut.zk);
        if (total_bad == 0 && layer == 7)
            $display("PASS: all 7 inverse NTT layers and the scaled output match Python");
        else
            $display("FAIL");
        $finish;
    end

endmodule
