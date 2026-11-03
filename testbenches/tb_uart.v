`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// tb_uart.v  (Khushi) - two uart_link instances (board A and board B)
// wired TX->RX both ways, with switches in the middle to break the wire.
//
// The baud rate and timeouts are sped up (INC = 16384 -> 1 bit = 64 clocks)
// so the simulation finishes quickly. The logic is identical at 115200.
//
//   iverilog -g2005 -o sim_uart tb/tb_uart.v rtl/uart_link.v rtl/baud_gen.v rtl/uart_tx.v rtl/uart_rx.v rtl/sync_fifo.v rtl/pkt_tx.v rtl/pkt_rx.v
//   vvp sim_uart
//////////////////////////////////////////////////////////////////////////////
module tb_uart;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    localparam AW = 7;

    // wires between the boards, with "cable" controls
    wire a_tx, b_tx;
    reg  cut_ab = 0, cut_ba = 0;      // 1 = wire pulled (line idles high)
    reg  glitch_ab = 0;               // 1 = invert the line (noise)
    wire b_rx = cut_ab ? 1'b1 : (a_tx ^ glitch_ab);
    wire a_rx = cut_ba ? 1'b1 : b_tx;

    // board A ports
    reg            a_we = 0; reg [AW-1:0] a_wa = 0; reg [7:0] a_wd = 0;
    reg  [7:0]     a_len = 0; reg a_send = 0; reg a_fault = 0;
    wire           a_busy, a_done, a_fail, a_rxv;
    reg  [AW-1:0]  a_ra = 0; wire [7:0] a_rd, a_rlen, a_rtype, a_seq;
    wire [11:0]    a_s, a_r, a_e, a_n;
    // board B ports
    reg            b_we = 0; reg [AW-1:0] b_wa = 0; reg [7:0] b_wd = 0;
    reg  [7:0]     b_len = 0; reg b_send = 0; reg b_fault = 0;
    wire           b_busy, b_done, b_fail, b_rxv;
    reg  [AW-1:0]  b_ra = 0; wire [7:0] b_rd, b_rlen, b_rtype, b_seq;
    wire [11:0]    b_s, b_r, b_e, b_n;

    uart_link #(.AW(AW), .BYTE_TMO(2000), .ACK_TIMEOUT(40000), .BAUD_INC(16'd16384)) A (
        .clk(clk), .rst(rst), .rx_pin(a_rx), .tx_pin(a_tx),
        .tx_wr_en(a_we), .tx_wr_addr(a_wa), .tx_wr_data(a_wd), .tx_len(a_len),
        .tx_type(8'h10), .tx_send(a_send), .tx_busy(a_busy), .tx_done(a_done), .tx_fail(a_fail),
        .rx_rd_addr(a_ra), .rx_rd_data(a_rd), .rx_len(a_rlen), .rx_type(a_rtype), .rx_valid(a_rxv),
        .fault_inject(a_fault), .tick16_out(), .tx_seq(a_seq),
        .cnt_sent(a_s), .cnt_recv(a_r), .cnt_err(a_e), .cnt_retry(a_n));

    uart_link #(.AW(AW), .BYTE_TMO(2000), .ACK_TIMEOUT(40000), .BAUD_INC(16'd16384)) B (
        .clk(clk), .rst(rst), .rx_pin(b_rx), .tx_pin(b_tx),
        .tx_wr_en(b_we), .tx_wr_addr(b_wa), .tx_wr_data(b_wd), .tx_len(b_len),
        .tx_type(8'h20), .tx_send(b_send), .tx_busy(b_busy), .tx_done(b_done), .tx_fail(b_fail),
        .rx_rd_addr(b_ra), .rx_rd_data(b_rd), .rx_len(b_rlen), .rx_type(b_rtype), .rx_valid(b_rxv),
        .fault_inject(b_fault), .tick16_out(), .tx_seq(b_seq),
        .cnt_sent(b_s), .cnt_recv(b_r), .cnt_err(b_e), .cnt_retry(b_n));

    // count events
    integer a_done_n = 0, a_fail_n = 0, b_rxv_n = 0, b_done_n = 0, a_rxv_n = 0;
    always @(posedge clk) begin
        if (a_done) a_done_n = a_done_n + 1;
        if (a_fail) a_fail_n = a_fail_n + 1;
        if (b_rxv)  b_rxv_n  = b_rxv_n + 1;
        if (b_done) b_done_n = b_done_n + 1;
        if (a_rxv)  a_rxv_n  = a_rxv_n + 1;
    end

    reg [7:0] pay_a [0:127];
    reg [7:0] pay_b [0:127];
    integer i, errors = 0, seed = 7;

    task load_a; input integer n;
        begin
            for (i = 0; i < n; i = i + 1) begin
                pay_a[i] = $random(seed);
                @(negedge clk); a_we = 1; a_wa = i; a_wd = pay_a[i];
            end
            @(negedge clk); a_we = 0; a_len = n;
        end
    endtask
    task load_b; input integer n;
        begin
            for (i = 0; i < n; i = i + 1) begin
                pay_b[i] = $random(seed);
                @(negedge clk); b_we = 1; b_wa = i; b_wd = pay_b[i];
            end
            @(negedge clk); b_we = 0; b_len = n;
        end
    endtask
    task send_a; begin @(negedge clk); a_send = 1; @(negedge clk); a_send = 0; end endtask
    task send_b; begin @(negedge clk); b_send = 1; @(negedge clk); b_send = 0; end endtask
    task wait_a; begin @(posedge clk); while (a_busy) @(posedge clk); end endtask
    task wait_b; begin @(posedge clk); while (b_busy) @(posedge clk); end endtask
    task settle; begin repeat (60000) @(posedge clk); end endtask

    task check_b; input integer n;
        begin
            if (b_rlen != n) begin $display("  FAIL: B rx_len %0d, expected %0d", b_rlen, n); errors = errors + 1; end
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk); b_ra = i; #1;
                if (b_rd !== pay_a[i]) begin
                    $display("  FAIL: B byte %0d = %h, expected %h", i, b_rd, pay_a[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask
    task check_a; input integer n;
        begin
            if (a_rlen != n) begin $display("  FAIL: A rx_len %0d, expected %0d", a_rlen, n); errors = errors + 1; end
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk); a_ra = i; #1;
                if (a_rd !== pay_b[i]) begin errors = errors + 1; end
            end
        end
    endtask
    task expect; input integer got, want; input [8*40-1:0] what;
        begin
            if (got != want) begin
                $display("  FAIL: %0s = %0d, expected %0d", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer k, t0, bv0, ad0, af0;
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (100) @(posedge clk);

        //-------------------------------------------------------------
        $display("Test 1: A sends 32 bytes to B (clean wire)");
        load_a(32); send_a; wait_a; settle;
        expect(a_done_n, 1, "A tx_done count");
        expect(b_rxv_n, 1, "B rx_valid count");
        check_b(32);
        expect(b_rtype, 8'h10, "B rx_type");

        //-------------------------------------------------------------
        $display("Test 2: fault injection -> NAK -> automatic re-send");
        @(negedge clk); a_fault = 1; @(negedge clk); a_fault = 0;
        load_a(20); send_a; wait_a; settle;
        expect(a_done_n, 2, "A tx_done count");
        expect(b_rxv_n, 2, "B rx_valid count");
        check_b(20);
        expect(b_e, 12'h001, "B error counter (BCD)");
        expect(a_n, 12'h001, "A retry counter (BCD)");

        //-------------------------------------------------------------
        $display("Test 3: wire cut mid-packet, restored -> byte timeout, retry, success");
        load_a(64); send_a;
        repeat (64*10*6) @(posedge clk);     // ~6 bytes into the packet
        cut_ab = 1;
        repeat (30000) @(posedge clk);
        cut_ab = 0;
        wait_a; settle;
        expect(a_done_n, 3, "A tx_done count");
        expect(b_rxv_n, 3, "B rx_valid count");
        check_b(64);
        $display("  B errors now %h (timeout counted), A retries %h", b_e, a_n);

        //-------------------------------------------------------------
        $display("Test 4: ACK lost (B->A cut) -> A re-sends, B must NOT deliver twice");
        bv0 = b_rxv_n;
        load_a(10); send_a;
        // cut B->A while B is replying
        @(posedge b_rxv);
        cut_ba = 1;
        repeat (20000) @(posedge clk);
        cut_ba = 0;
        wait_a; settle;
        expect(a_done_n, 4, "A tx_done count");
        expect(b_rxv_n - bv0, 1, "B deliveries for one message");
        check_b(10);

        //-------------------------------------------------------------
        $display("Test 5: wire cut for good -> A gives up after 3 retries (tx_fail)");
        af0 = a_fail_n;
        cut_ab = 1;
        load_a(8); send_a; wait_a;
        cut_ab = 0; settle;
        expect(a_fail_n - af0, 1, "A tx_fail count");

        //-------------------------------------------------------------
        $display("Test 6: next message after a failure still goes through");
        bv0 = b_rxv_n; ad0 = a_done_n;
        load_a(16); send_a; wait_a; settle;
        expect(a_done_n - ad0, 1, "A tx_done count");
        expect(b_rxv_n - bv0, 1, "B rx_valid count");
        check_b(16);

        //-------------------------------------------------------------
        $display("Test 7: both boards send at the same time");
        load_a(40); load_b(25);
        fork send_a; send_b; join
        wait_a; wait_b; settle;
        check_b(40);
        check_a(25);
        expect(b_done_n, 1, "B tx_done count");
        expect(a_rxv_n, 1, "A rx_valid count");

        //-------------------------------------------------------------
        $display("Test 8: 30 random packets with random 1-clock glitches on the wire");
        ad0 = a_done_n; bv0 = b_rxv_n;
        for (k = 0; k < 30; k = k + 1) begin
            load_a(1 + ($random(seed) & 127));
            send_a;
            while (a_busy) begin
                @(posedge clk);
                glitch_ab = (($random(seed) & 1023) == 0);   // rare 10 ns spikes
            end
            glitch_ab = 0;
            settle;
            check_b(a_len);
        end
        expect(a_done_n - ad0, 30, "A tx_done count");
        expect(b_rxv_n - bv0, 30, "B rx_valid count");

        $display("Final counters  A: sent %h recv %h err %h retry %h | B: sent %h recv %h err %h retry %h",
                 a_s, a_r, a_e, a_n, b_s, b_r, b_e, b_n);
        if (errors == 0) $display("ALL UART TESTS PASS");
        else             $display("%0d UART CHECKS FAILED", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT - simulation hung");
        $finish;
    end
endmodule
