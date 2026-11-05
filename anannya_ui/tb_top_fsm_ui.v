`timescale 1ns / 1ps
module tb_top_fsm;
    reg clk = 0, rst = 1;
    reg send_req = 0, send_req2 = 0, rx_clear = 0;
    reg [127:0] msg_in = 128'd0;
    reg [4:0]   msg_len_in = 5'd0;
    wire tx_pin, tx_pin2, ok, fail, busy, ok2, fail2, busy2;
    wire [127:0] rx_log, rx_log2;
    wire [4:0]   rx_n, rx_n2;
    integer errors = 0;
    integer t, i;
    reg [127:0] m;

    always #5 clk = ~clk;                          // 100 MHz

    // DUT 1: loopback, default timeouts
    top_fsm #(.MAXLEN(16)) dut (
        .clk(clk), .rst(rst), .loopback(1'b1), .rx_pin(1'b1), .tx_pin(tx_pin),
        .send_req(send_req), .msg_in(msg_in), .msg_len_in(msg_len_in),
        .rx_clear(rx_clear), .send_ok(ok), .send_fail(fail), .tx_busy(busy),
        .rx_log(rx_log), .rx_n(rx_n));

    // DUT 2: no loop, nothing answers -> must give up (short timeout keeps the sim fast)
    top_fsm #(.MAXLEN(16), .ACK_TIMEOUT(20000)) dut2 (
        .clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(1'b1), .tx_pin(tx_pin2),
        .send_req(send_req2), .msg_in(msg_in), .msg_len_in(msg_len_in),
        .rx_clear(1'b0), .send_ok(ok2), .send_fail(fail2), .tx_busy(busy2),
        .rx_log(rx_log2), .rx_n(rx_n2));

    // send a message on DUT 1 and wait for the result
    task send_msg;
        input [127:0] mm;
        input [4:0]   n;
        input [255:0] tag;
        begin
            @(posedge clk); #1; msg_in = mm; msg_len_in = n; send_req = 1;
            @(posedge clk); #1; send_req = 0;
            t = 0;
            while (!ok && !fail && t < 600000) begin
                @(posedge clk); t = t + 1;
            end
            if (!ok) begin errors = errors + 1; $display("FAIL %0s: send not OK (n=%0d)", tag, n); end
            repeat (50) @(posedge clk);
        end
    endtask

    task check_rx;
        input [127:0] exp;
        input [4:0]   n;
        input [255:0] tag;
        integer k;
        begin
            if (rx_n !== n) begin
                errors = errors + 1;
                $display("FAIL %0s: rx_n = %0d, want %0d", tag, rx_n, n);
            end
            for (k = 0; k < n; k = k + 1)
                if (rx_log[k*8 +: 8] !== exp[k*8 +: 8]) begin
                    errors = errors + 1;
                    $display("FAIL %0s: byte %0d = %h, want %h", tag, k, rx_log[k*8 +: 8], exp[k*8 +: 8]);
                end
        end
    endtask

    initial begin
        #80_000_000;
        $display("FAIL: timeout");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk);
        #1 rst = 0;
        repeat (10) @(posedge clk);

        // ---- 3 characters ----
        m = {104'd0, "!", "I", "H"};
        send_msg(m, 5'd3, "HI!");          check_rx(m, 5'd3, "HI!");

        // ---- a second message REPLACES the first ----
        m = {112'd0, "K", "O"};
        send_msg(m, 5'd2, "OK");           check_rx(m, 5'd2, "OK");

        // ---- full 16 bytes ----
        for (i = 0; i < 16; i = i + 1) m[i*8 +: 8] = 8'h10 + 3*i;
        send_msg(m, 5'd16, "16 bytes");    check_rx(m, 5'd16, "16 bytes");

        // ---- bytes that look special: 0x7E is the packet start marker, plus 0x00 and 0xFF ----
        m = 128'd0;
        m[7:0] = 8'h80; m[15:8] = 8'h7E; m[23:16] = 8'h00; m[31:24] = 8'hFF;
        send_msg(m, 5'd4, "special bytes"); check_rx(m, 5'd4, "special bytes");

        // ---- an empty message is ignored ----
        @(posedge clk); #1 msg_len_in = 5'd0; send_req = 1;
        @(posedge clk); #1 send_req = 0;
        repeat (200) @(posedge clk);
        if (busy !== 1'b0)  begin errors = errors + 1; $display("FAIL empty: busy"); end
        if (rx_n !== 5'd4)  begin errors = errors + 1; $display("FAIL empty: log changed"); end

        // ---- clear ----
        @(posedge clk); #1 rx_clear = 1;
        @(posedge clk); #1 rx_clear = 0;
        repeat (5) @(posedge clk);
        if (rx_n !== 5'd0 || rx_log !== 128'd0) begin errors = errors + 1; $display("FAIL clear"); end

        // ---- DUT 2: nobody answers -> send_fail, nothing received ----
        @(posedge clk); #1 msg_in = {120'd0, "A"}; msg_len_in = 5'd1; send_req2 = 1;
        @(posedge clk); #1 send_req2 = 0;
        t = 0;
        while (!ok2 && !fail2 && t < 3000000) begin
            @(posedge clk); t = t + 1;
        end
        if (!fail2 || ok2)  begin errors = errors + 1; $display("FAIL dut2: expected send_fail"); end
        repeat (20) @(posedge clk);
        if (busy2 !== 1'b0) begin errors = errors + 1; $display("FAIL dut2: still busy"); end
        if (rx_n2 !== 5'd0) begin errors = errors + 1; $display("FAIL dut2: received something"); end

        if (errors == 0) $display("PASS: tb_top_fsm");
        else             $display("FAIL: tb_top_fsm, %0d errors", errors);
        $finish;
    end
endmodule