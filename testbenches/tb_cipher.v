`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// tb_cipher.v  (Khushi) - two boards, ciphertext as 12 x 128-byte packets
//
// Board A and board B each have top_fsm (uart_link inside) + cipher_link,
// wired TX -> RX both ways like the real JA cable. The test sender is
// Shrikkanth's ciphertext_uart_tx fed from ct_source, so the packets are the
// same as a real encrypted send (types 0x10..0x1B, 128 bytes each). Tests:
//   1. A sends the 768-word ciphertext; B rebuilds it and ct_check passes.
//      B's RAM is also compared word by word against the .mem files here.
//   2. Same again with fault_inject on A during the send: one packet is
//      NAKed and re-sent, and the result must still pass.
//   3. A short plaintext message (type 0x10, 2 bytes) still reaches the text
//      reader and is NOT taken as a ciphertext fragment.
//   4. B sends the ciphertext back to A (both directions work).
//   Each received ciphertext is also decrypted (rx_decrypt -> decryption_ntt):
//   the test vector must come out as "Kryptonite FPGA " (16 chars, 15 shown).
// Needs u0.mem, u1.mem, v.mem (crypto/test_vectors/ciphertext/) in the
// folder the simulator runs in, plus the decryption tables s0_hat.mem,
// s1_hat.mem, gammas.mem, zetas.mem (sources_1/imports/mem_files). To keep the run short the links use 921600
// baud (BAUD_INC 9664) and a 4 ms ACK timeout; the logic is identical.
// About 60 ms simulated: use "run all".
//////////////////////////////////////////////////////////////////////////////
module tb_cipher;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    wire a_tx, b_tx;
    integer errors = 0;

    // ---------------- board A ----------------
    reg         a_send = 0, a_fault = 0, a_tsend = 0;
    reg [127:0] a_msg = 0; reg [4:0] a_len = 0;
    wire a_ok, a_failt, a_busy, a_rxnew;
    wire [127:0] a_log; wire [4:0] a_n;
    wire [11:0] a_cs, a_cr, a_ce, a_cn;
    wire a_ctb, a_we, a_snd, a_lb, a_ld, a_lf, a_rxv;
    wire [6:0] a_wa, a_ra; wire [7:0] a_wd, a_len8, a_ty, a_rt, a_rl, a_rd;
    wire a_txok, a_txbad, a_rdy, a_new, a_pass, a_fail; wire [11:0] a_rm; wire [9:0] a_mm;

    top_fsm #(.MAXLEN(16), .ACK_TIMEOUT(400000), .BYTE_TMO(20000), .BAUD_INC(16'd9664)) fa (.clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(b_tx), .tx_pin(a_tx),
        .send_req(a_tsend), .msg_in(a_msg), .msg_len_in(a_len), .rx_clear(1'b0),
        .retry_req(1'b0), .mul_done(1'b0), .mul_rd_data(12'd0),
        .send_ok(a_ok), .send_fail(a_failt), .tx_busy(a_busy), .rx_log(a_log), .rx_n(a_n),
        .fault_inject(a_fault), .rx_new(a_rxnew),
        .cnt_sent(a_cs), .cnt_recv(a_cr), .cnt_err(a_ce), .cnt_retry(a_cn),
        .ct_busy(a_ctb), .ct_we(a_we), .ct_wa(a_wa), .ct_wd(a_wd), .ct_len(a_len8), .ct_type(a_ty), .ct_send(a_snd),
        .lk_busy(a_lb), .lk_done(a_ld), .lk_fail(a_lf), .ct_ra(a_ra),
        .lk_rxv(a_rxv), .lk_rtype(a_rt), .lk_rlen(a_rl), .lk_rd(a_rd));
    cipher_link ca (.clk(clk), .rst(rst), .test_send(a_send), .clear(1'b0),
        .tx_ok(a_txok), .tx_bad(a_txbad),
        .rx_mask(a_rm), .ct_ready(a_rdy), .ct_new(a_new),
        .chk_pass(a_pass), .chk_fail(a_fail), .chk_mismatch(a_mm),
        .dec_busy(), .msg_new(a_mnew), .msg_log(a_mlog), .msg_n(a_mn),
        .ct_busy(a_ctb), .ct_we(a_we), .ct_wa(a_wa), .ct_wd(a_wd), .ct_len(a_len8), .ct_type(a_ty), .ct_send(a_snd),
        .lk_busy(a_lb), .lk_done(a_ld), .lk_fail(a_lf), .ct_ra(a_ra),
        .lk_rxv(a_rxv), .lk_rtype(a_rt), .lk_rlen(a_rl), .lk_rd(a_rd));

    // ---------------- board B ----------------
    reg         b_send = 0;
    wire a_mnew, b_mnew; wire [127:0] a_mlog, b_mlog; wire [4:0] a_mn, b_mn;
    reg  [127:0] want_txt;
    integer j, txt_ok;
    initial begin                        // "Kryptonite FPGA " with byte 0 in [7:0]
        want_txt = 0;
        want_txt = {"K","r","y","p","t","o","n","i","t","e"," ","F","P","G","A",8'h00};  // padding cleared
        for (j = 0; j < 8; j = j + 1) begin   // reverse the byte order
            {want_txt[8*j +: 8], want_txt[8*(15-j) +: 8]} = {want_txt[8*(15-j) +: 8], want_txt[8*j +: 8]};
        end
    end
    wire b_ok, b_failt, b_busy, b_rxnew;
    wire [127:0] b_log; wire [4:0] b_n;
    wire [11:0] b_cs, b_cr, b_ce, b_cn;
    wire b_ctb, b_we, b_snd, b_lb, b_ld, b_lf, b_rxv;
    wire [6:0] b_wa, b_ra; wire [7:0] b_wd, b_len8, b_ty, b_rt, b_rl, b_rd;
    wire b_txok, b_txbad, b_rdy, b_new, b_pass, b_fail; wire [11:0] b_rm; wire [9:0] b_mm;

    top_fsm #(.MAXLEN(16), .ACK_TIMEOUT(400000), .BYTE_TMO(20000), .BAUD_INC(16'd9664)) fb (.clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(a_tx), .tx_pin(b_tx),
        .send_req(1'b0), .msg_in(128'd0), .msg_len_in(5'd0), .rx_clear(1'b0),
        .retry_req(1'b0), .mul_done(1'b0), .mul_rd_data(12'd0),
        .send_ok(b_ok), .send_fail(b_failt), .tx_busy(b_busy), .rx_log(b_log), .rx_n(b_n),
        .fault_inject(1'b0), .rx_new(b_rxnew),
        .cnt_sent(b_cs), .cnt_recv(b_cr), .cnt_err(b_ce), .cnt_retry(b_cn),
        .ct_busy(b_ctb), .ct_we(b_we), .ct_wa(b_wa), .ct_wd(b_wd), .ct_len(b_len8), .ct_type(b_ty), .ct_send(b_snd),
        .lk_busy(b_lb), .lk_done(b_ld), .lk_fail(b_lf), .ct_ra(b_ra),
        .lk_rxv(b_rxv), .lk_rtype(b_rt), .lk_rlen(b_rl), .lk_rd(b_rd));
    cipher_link cb (.clk(clk), .rst(rst), .test_send(b_send), .clear(1'b0),
        .tx_ok(b_txok), .tx_bad(b_txbad),
        .rx_mask(b_rm), .ct_ready(b_rdy), .ct_new(b_new),
        .chk_pass(b_pass), .chk_fail(b_fail), .chk_mismatch(b_mm),
        .dec_busy(), .msg_new(b_mnew), .msg_log(b_mlog), .msg_n(b_mn),
        .ct_busy(b_ctb), .ct_we(b_we), .ct_wa(b_wa), .ct_wd(b_wd), .ct_len(b_len8), .ct_type(b_ty), .ct_send(b_snd),
        .lk_busy(b_lb), .lk_done(b_ld), .lk_fail(b_lf), .ct_ra(b_ra),
        .lk_rxv(b_rxv), .lk_rtype(b_rt), .lk_rlen(b_rl), .lk_rd(b_rd));

    // ---------------- reference copy ----------------
    reg [11:0] ref_ct [0:767];
    initial begin
        $readmemh("u0.mem", ref_ct,   0, 255);
        $readmemh("u1.mem", ref_ct, 256, 511);
        $readmemh("v.mem",  ref_ct, 512, 767);
    end

    task check(input [8*40-1:0] name, input cond);
        begin
            if (cond) $display("  ok   %0s", name);
            else begin $display("  FAIL %0s", name); errors = errors + 1; end
        end
    endtask

    // read B's received RAM through the decryptor port and compare
    integer i, bad;
    task compare_b_ram;
        begin
            bad = 0;
            for (i = 0; i < 768; i = i + 1) begin
                if (cb.u_rx.ram[i] !== ref_ct[i]) bad = bad + 1;
            end
            check("B RAM equals the .mem files (768 words)", bad == 0);
        end
    endtask


    initial begin
        repeat (20) @(negedge clk); rst = 0;
        repeat (100) @(negedge clk);

        $display("1. A sends the ciphertext to B");
        @(negedge clk) a_send = 1; @(negedge clk) a_send = 0;
        wait (a_txok || a_txbad);
        wait (b_pass || b_fail);
        repeat (5) @(negedge clk);
        check("A: all 12 packets delivered", a_txok);
        check("B: all 12 fragments received", b_rdy && b_rm == 12'hFFF);
        check("B: ct_check pass, 0 mismatches", b_pass && !b_fail && b_mm == 0);
        check("A: 12 data packets counted as sent", a_cs == 12'h012);
        compare_b_ram;
        wait (b_mlog == want_txt || $time > 999_000_000_000);
        repeat (5) @(negedge clk);
        check("B: decrypted to \"Kryptonite FPGA\"", b_mlog == want_txt && b_mn == 15);

        $display("2. Again, with a corrupted packet on the way");
        @(negedge clk) a_send = 1; @(negedge clk) a_send = 0;
        repeat (300000) @(negedge clk);              // a few chunks in
        @(negedge clk) a_fault = 1; @(negedge clk) a_fault = 0;
        wait (a_txok || a_txbad);
        wait (b_pass || b_fail);
        repeat (5) @(negedge clk);
        check("A: still all 12 delivered", a_txok);
        check("B: ct_check pass after the re-send", b_pass && b_mm == 0);
        check("A: one re-send counted", a_cn == 12'h001);
        check("B: one bad packet counted", b_ce == 12'h001);

        $display("3. Text message still works");
        a_msg = "21"; a_len = 2;
        @(negedge clk) a_tsend = 1; @(negedge clk) a_tsend = 0;
        wait (a_ok || a_failt);                      // B has the text before A sees the ACK
        repeat (5) @(negedge clk);
        check("A: text send OK", a_ok);
        check("B: received \"12\" as 2 bytes", b_n == 2 && b_log[15:0] == "21");
        check("B: not taken as a fragment", b_rm == 12'hFFF && b_pass);

        $display("4. B sends the ciphertext back to A");
        @(negedge clk) b_send = 1; @(negedge clk) b_send = 0;
        wait (b_txok || b_txbad);
        wait (a_pass || a_fail);
        repeat (5) @(negedge clk);
        check("A: ct_check pass", a_pass && a_mm == 0);
        repeat (40000) @(negedge clk);           // decryption takes ~34k clocks
        check("A: decrypted to \"Kryptonite FPGA\"", a_mlog == want_txt && a_mn == 15);

        if (errors == 0) $display("ALL CIPHER TESTS PASSED");
        else             $display("%0d CIPHER TEST(S) FAILED", errors);
        $finish;
    end

    initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
