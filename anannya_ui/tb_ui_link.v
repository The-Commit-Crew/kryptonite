`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 07:37:49 PM
// Design Name: 
// Module Name: tb_ui_link
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


module tb_ui_link;
    reg clk = 0;
    reg rst = 1;
    reg send_pulse = 0;
    reg [7:0] send_byte = 0;
    reg rx_clear = 0;
    wire tx_pin, send_ok, send_fail, link_busy;
    wire [127:0] rx_log;
    wire [4:0]   rx_n;
    integer errors = 0;

    always #5 clk = ~clk;                       // 100 MHz

    ui_link #(.LOGN(16)) dut (
        .clk(clk), .rst(rst),
        .send_pulse(send_pulse), .send_byte(send_byte),
        .rx_clear(rx_clear), .loopback(1'b1),
        .rx_pin(1'b1), .tx_pin(tx_pin),
        .send_ok(send_ok), .send_fail(send_fail),
        .rx_log(rx_log), .rx_n(rx_n), .tx_busy(link_busy));

    // pulse send for one clock, wait for the ACK
    task send_digit;
        input [7:0] b;
        integer t;
        begin
            @(posedge clk); #1;
            send_byte = b; send_pulse = 1;
            @(posedge clk); #1;
            send_pulse = 0;
            repeat (8) @(posedge clk);          // let send_ok clear first
            t = 0;
            while (!send_ok && !send_fail && t < 400000) begin
                @(posedge clk); t = t + 1;
            end
            if (!send_ok) begin
                errors = errors + 1;
                $display("FAIL: no send_ok for %h", b);
            end
            repeat (20) @(posedge clk);         // let the RX log finish
        end
    endtask

    initial begin
        #40_000_000;                            // 40 ms watchdog
        $display("FAIL: timeout");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        send_digit(8'h03);
        send_digit(8'h07);
        send_digit(8'h09);

        if (rx_n !== 5'd3)           begin errors = errors + 1; $display("FAIL: rx_n = %0d, want 3", rx_n); end
        if (rx_log[7:0]   !== 8'h03) begin errors = errors + 1; $display("FAIL: byte0 = %h", rx_log[7:0]); end
        if (rx_log[15:8]  !== 8'h07) begin errors = errors + 1; $display("FAIL: byte1 = %h", rx_log[15:8]); end
        if (rx_log[23:16] !== 8'h09) begin errors = errors + 1; $display("FAIL: byte2 = %h", rx_log[23:16]); end
        if (send_ok !== 1'b1 || send_fail !== 1'b0) begin errors = errors + 1; $display("FAIL: status latch"); end

        // clear the log
        @(posedge clk); #1 rx_clear = 1;
        @(posedge clk); #1 rx_clear = 0;
        repeat (5) @(posedge clk);
        if (rx_n !== 5'd0 || rx_log !== 128'd0) begin errors = errors + 1; $display("FAIL: clear"); end

        if (errors == 0) $display("PASS: tb_ui_link");
        else             $display("FAIL: tb_ui_link, %0d errors", errors);
        $finish;
    end
endmodule
