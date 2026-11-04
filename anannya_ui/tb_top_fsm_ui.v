`timescale 1ns / 1ps
module tb_top_fsm;
    reg clk = 0, rst = 1;
    reg send_req = 0, send_req2 = 0, rx_clear = 0;
    reg [63:0] msg_in = 64'd0;
    reg [4:0]  msg_len_in = 5'd0;
    wire tx_pin, tx_pin2, ok, fail, busy, ok2, fail2, busy2;
    wire [127:0] rx_log, rx_log2;
    wire [4:0]   rx_n, rx_n2;
    wire [63:0]  rmsg, rmsg2;
    wire [4:0]   rmsg_len, rmsg_len2;
    integer errors = 0;
    integer t;

    always #5 clk = ~clk;                          // 100 MHz

    // DUT 1: loopback, default timeouts
    top_fsm #(.MAXLEN(16)) dut (
        .clk(clk), .rst(rst), .loopback(1'b1), .rx_pin(1'b1), .tx_pin(tx_pin),
        .send_req(send_req), .msg_in(msg_in), .msg_len_in(msg_len_in),
        .rx_clear(rx_clear), .send_ok(ok), .send_fail(fail), .tx_busy(busy),
        .rx_log(rx_log), .rx_n(rx_n), .rmsg(rmsg), .rmsg_len(rmsg_len));

    // DUT 2: no loop, nothing answers -> must give up (short timeout to keep the sim fast)
    top_fsm #(.MAXLEN(16), .ACK_TIMEOUT(20000)) dut2 (
        .clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(1'b1), .tx_pin(tx_pin2),
        .send_req(send_req2), .msg_in(msg_in), .msg_len_in(msg_len_in),
        .rx_clear(1'b0), .send_ok(ok2), .send_fail(fail2), .tx_busy(busy2),
        .rx_log(rx_log2), .rx_n(rx_n2), .rmsg(rmsg2), .rmsg_len(rmsg_len2));

    // send a message on DUT 1 and wait for the result
    task send_msg;
        input [63:0] m;
        input [4:0]  n;
        begin
            @(posedge clk); #1; msg_in = m; msg_len_in = n; send_req = 1;
            @(posedge clk); #1; send_req = 0;
            t = 0;
            while (!ok && !fail && t < 600000) begin
                @(posedge clk); t = t + 1;
            end
            if (!ok) begin errors = errors + 1; $display("FAIL: send not OK (n=%0d)", n); end
            repeat (50) @(posedge clk);
        end
    endtask

    initial begin
        #60_000_000;
        $display("FAIL: timeout");
        $finish;
    end

    integer i;
    initial begin
        repeat (10) @(posedge clk);
        #1 rst = 0;
        repeat (10) @(posedge clk);

        // ---- message 1: digits 3 7 9 ----
        send_msg(64'h973, 5'd3);
        if (rx_n !== 5'd3 || rmsg_len !== 5'd3)  begin errors = errors + 1; $display("FAIL m1 counts %0d %0d", rx_n, rmsg_len); end
        if (rmsg[11:0] !== 12'h973)              begin errors = errors + 1; $display("FAIL m1 digits %h", rmsg[11:0]); end
        if (rx_log[7:0] !== 8'h03 || rx_log[15:8] !== 8'h07 || rx_log[23:16] !== 8'h09)
                                                 begin errors = errors + 1; $display("FAIL m1 bytes"); end

        // ---- message 2 (digits 5 1) REPLACES message 1 ----
        send_msg(64'h15, 5'd2);
        if (rx_n !== 5'd2 || rmsg_len !== 5'd2)  begin errors = errors + 1; $display("FAIL m2 counts %0d %0d", rx_n, rmsg_len); end
        if (rmsg[7:0] !== 8'h15)                 begin errors = errors + 1; $display("FAIL m2 digits %h", rmsg[7:0]); end
        if (rx_log[7:0] !== 8'h05 || rx_log[15:8] !== 8'h01)
                                                 begin errors = errors + 1; $display("FAIL m2 bytes"); end

        // ---- a full 16-digit message (digit k = k) ----
        send_msg(64'hFEDCBA9876543210, 5'd16);
        if (rx_n !== 5'd16 || rmsg_len !== 5'd16) begin errors = errors + 1; $display("FAIL m3 counts %0d %0d", rx_n, rmsg_len); end
        if (rmsg !== 64'hFEDCBA9876543210)        begin errors = errors + 1; $display("FAIL m3 digits %h", rmsg); end
        for (i = 0; i < 16; i = i + 1)
            if (rx_log[i*8 +: 8] !== i[7:0])      begin errors = errors + 1; $display("FAIL m3 byte %0d", i); end

        // ---- an empty message is ignored ----
        @(posedge clk); #1; msg_len_in = 5'd0; send_req = 1;
        @(posedge clk); #1; send_req = 0;
        repeat (200) @(posedge clk);
        if (busy !== 1'b0)                        begin errors = errors + 1; $display("FAIL empty: busy"); end
        if (rx_n !== 5'd16)                       begin errors = errors + 1; $display("FAIL empty: log changed"); end

        // ---- clear ----
        @(posedge clk); #1; rx_clear = 1;
        @(posedge clk); #1; rx_clear = 0;
        repeat (5) @(posedge clk);
        if (rx_n !== 5'd0 || rmsg_len !== 5'd0 || rmsg !== 64'd0 || rx_log !== 128'd0)
                                                  begin errors = errors + 1; $display("FAIL clear"); end

        // ---- DUT 2: nobody answers -> send_fail, nothing received ----
        @(posedge clk); #1; msg_in = 64'h973; msg_len_in = 5'd3; send_req2 = 1;
        @(posedge clk); #1; send_req2 = 0;
        t = 0;
        while (!ok2 && !fail2 && t < 3000000) begin
            @(posedge clk); t = t + 1;
        end
        if (!fail2 || ok2)                        begin errors = errors + 1; $display("FAIL dut2: expected send_fail"); end
        repeat (20) @(posedge clk);
        if (busy2 !== 1'b0)                       begin errors = errors + 1; $display("FAIL dut2: still busy"); end
        if (rx_n2 !== 5'd0)                       begin errors = errors + 1; $display("FAIL dut2: received something"); end

        if (errors == 0) $display("PASS: tb_top_fsm");
        else             $display("FAIL: tb_top_fsm, %0d errors", errors);
        $finish;
    end
endmodule