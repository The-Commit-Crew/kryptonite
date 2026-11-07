`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// tb_e2e.v  (Khushi) - the whole message path, encryption to display
//
//   Board A (sender):   top_fsm with ENCRYPT_SEND = 1 -> board1_message_tx
//                       -> board1_send (live noise, Shrikkanth's
//                       shared_poly_multiplier) -> 12 ciphertext packets
//   Board B (receiver): top_fsm -> cipher_rx (rebuild) -> rx_decrypt
//                       (Divyansh's decryption_ntt) -> message bytes
//
// Tests:
//   1. A encrypts and sends "4321"; B must decrypt exactly "4321" (length 4).
//   2. A sends "907" with a corrupted packet on the way; B still gets "907".
//   3. A sends a full 16-digit message; B gets all 16 digits.
// Each send uses fresh random noise, so the ciphertext differs every time.
//
// Files needed in the simulator's folder:
//   crypto/keys/board1/*.mem               (the public key, relative path as on main)
//   zetas.mem gammas.mem s0_hat.mem s1_hat.mem   (sources_1/imports/mem_files)
//   u0.mem u1.mem v.mem                    (test vector, used by ct_source)
// The links run at 921600 baud with a 4 ms ACK timeout to keep the run short.
//////////////////////////////////////////////////////////////////////////////
module tb_e2e;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    integer errors = 0;

    wire a_tx, b_tx;

    // ---------------- board A: encrypting sender ----------------
    reg         a_send = 0, a_fault = 0;
    reg [127:0] a_msg = 0; reg [4:0] a_len = 0;
    wire a_ok, a_fail, a_busy, a_rxnew;
    wire [127:0] a_log; wire [4:0] a_n;
    wire [11:0] a_cs, a_cr, a_ce, a_cn;
    wire m_we, m_start, m_done; wire [7:0] m_wa, m_ra; wire [11:0] m_l, m_r, m_rd;

    wire [95:0] a_head;                  // first 12 ciphertext bytes A sent
    wire [71:0] a_words = {a_head[11:8],a_head[7:0], a_head[27:24],a_head[23:16],
                           a_head[43:40],a_head[39:32], a_head[59:56],a_head[55:48],
                           a_head[75:72],a_head[71:64], a_head[91:88],a_head[87:80]};
    wire [71:0] b_head;                  // first 6 coefficients B rebuilt
    reg  [71:0] prev_head = 0;

    top_fsm #(.MAXLEN(16), .ENCRYPT_SEND(1), .ACK_TIMEOUT(400000), .BYTE_TMO(20000),
              .BAUD_INC(16'd9664)) fa (
        .clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(b_tx), .tx_pin(a_tx),
        .send_req(a_send), .msg_in(a_msg), .msg_len_in(a_len), .rx_clear(1'b0),
        .send_ok(a_ok), .send_fail(a_fail), .tx_busy(a_busy), .rx_log(a_log), .rx_n(a_n),
        .retry_req(1'b0),
        .mul_wr_en(m_we), .mul_wr_addr(m_wa), .mul_left(m_l), .mul_right(m_r),
        .mul_start(m_start), .mul_done(m_done), .mul_rd_addr(m_ra), .mul_rd_data(m_rd),
        .fault_inject(a_fault), .rx_new(a_rxnew),
        .cnt_sent(a_cs), .cnt_recv(a_cr), .cnt_err(a_ce), .cnt_retry(a_cn),
        .ct_busy(1'b0), .ct_we(1'b0), .ct_wa(7'd0), .ct_wd(8'd0), .ct_len(8'd0),
        .ct_type(8'd0), .ct_send(1'b0),
        .lk_busy(), .lk_done(), .lk_fail(), .ct_ra(7'd0),
        .lk_rxv(), .lk_rtype(), .lk_rlen(), .lk_rd(), .tx_ct_head(a_head));
    shared_poly_multiplier mult (
        .clk(clk), .rst(rst), .wr_en(m_we), .wr_addr(m_wa), .left_data(m_l), .right_data(m_r),
        .start(m_start), .done(m_done), .rd_addr(m_ra), .rd_data(m_rd));

    // ---------------- board B: receiver + decryptor ----------------
    wire b_ok, b_failt, b_busy, b_rxnew;
    wire [127:0] b_log; wire [4:0] b_n;
    wire [11:0] b_cs, b_cr, b_ce, b_cn;
    wire b_ctb, b_we, b_snd, b_lb, b_ld, b_lf, b_rxv;
    wire [6:0] b_wa, b_ra; wire [7:0] b_wd, b_len8, b_ty, b_rt, b_rl, b_rd;
    wire b_txok, b_txbad, b_rdy, b_new, b_pass, b_fail; wire [11:0] b_rm; wire [9:0] b_mm;
    wire b_dbusy, b_mnew; wire [127:0] b_mlog; wire [4:0] b_mn;

    top_fsm #(.MAXLEN(16), .ACK_TIMEOUT(400000), .BYTE_TMO(20000), .BAUD_INC(16'd9664)) fb (
        .clk(clk), .rst(rst), .loopback(1'b0), .rx_pin(a_tx), .tx_pin(b_tx),
        .send_req(1'b0), .msg_in(128'd0), .msg_len_in(5'd0), .rx_clear(1'b0),
        .send_ok(b_ok), .send_fail(b_failt), .tx_busy(b_busy), .rx_log(b_log), .rx_n(b_n),
        .retry_req(1'b0), .mul_done(1'b0), .mul_rd_data(12'd0),
        .fault_inject(1'b0), .rx_new(b_rxnew),
        .cnt_sent(b_cs), .cnt_recv(b_cr), .cnt_err(b_ce), .cnt_retry(b_cn),
        .ct_busy(b_ctb), .ct_we(b_we), .ct_wa(b_wa), .ct_wd(b_wd), .ct_len(b_len8),
        .ct_type(b_ty), .ct_send(b_snd),
        .lk_busy(b_lb), .lk_done(b_ld), .lk_fail(b_lf), .ct_ra(b_ra),
        .lk_rxv(b_rxv), .lk_rtype(b_rt), .lk_rlen(b_rl), .lk_rd(b_rd));
    cipher_link cb (.clk(clk), .rst(rst), .test_send(1'b0), .clear(1'b0),
        .tx_ok(b_txok), .tx_bad(b_txbad),
        .rx_mask(b_rm), .ct_ready(b_rdy), .ct_new(b_new), .ct_head(b_head),
        .chk_pass(b_pass), .chk_fail(b_fail), .chk_mismatch(b_mm),
        .dec_busy(b_dbusy), .msg_new(b_mnew), .msg_log(b_mlog), .msg_n(b_mn),
        .ct_busy(b_ctb), .ct_we(b_we), .ct_wa(b_wa), .ct_wd(b_wd), .ct_len(b_len8),
        .ct_type(b_ty), .ct_send(b_snd),
        .lk_busy(b_lb), .lk_done(b_ld), .lk_fail(b_lf), .ct_ra(b_ra),
        .lk_rxv(b_rxv), .lk_rtype(b_rt), .lk_rlen(b_rl), .lk_rd(b_rd));

    task check(input [8*44-1:0] name, input cond);
        begin
            if (cond) $display("  ok   %0s", name);
            else begin $display("  FAIL %0s", name); errors = errors + 1; end
        end
    endtask

    // ASCII digits from a string literal ("4321" -> byte 0 = '4')
    function [127:0] bytes_of;
        input [127:0] s;
        input integer n;
        integer i;
        begin
            bytes_of = 0;
            for (i = 0; i < n; i = i + 1) bytes_of[8*i +: 8] = s[8*(n-1-i) +: 8];
        end
    endfunction

    reg [127:0] want;
    integer got_msgs = 0;
    always @(posedge clk) if (b_mnew) got_msgs = got_msgs + 1;

    task send_and_check(input [127:0] txt, input integer n, input fault);
        integer before;
        begin
            want  = bytes_of(txt, n);
            a_msg = want; a_len = n;
            before = got_msgs;
            @(negedge clk) a_send = 1; @(negedge clk) a_send = 0;
            if (fault) begin
                wait (a_cs != 12'h000 || a_cs == 12'h000);   // let encryption start
                repeat (200000) @(negedge clk);
                @(negedge clk) a_fault = 1; @(negedge clk) a_fault = 0;
            end
            wait (a_ok || a_fail);
            wait (got_msgs != before || a_fail);
            repeat (10) @(negedge clk);
            check("A: encrypted send delivered (send_ok)", a_ok && !a_fail);
            check("B: all 12 fragments rebuilt", b_rdy && b_rm == 12'hFFF);
            check("B: decrypted text matches", b_mlog == want);
            check("B: decrypted length matches", b_mn == n);
            check("display: B's ciphertext == what A sent", b_head == a_words && b_head != 0);
            check("display: ciphertext differs from last send", b_head != prev_head);
            $display("       ciphertext shown on both boards: %h", b_head[71:8]);
            prev_head = b_head;
            $display("       sent \"%0s\", B decrypted %0d chars", txt, b_mn);
        end
    endtask

    initial begin
        repeat (20) @(negedge clk); rst = 0;
        repeat (200) @(negedge clk);

        $display("1. Encrypt + send \"4321\"");
        send_and_check("4321", 4, 1'b0);

        $display("2. Encrypt + send \"907\" with a corrupted packet");
        send_and_check("907", 3, 1'b1);
        check("A: a re-send happened", a_cn != 12'h000);

        $display("3. Encrypt + send 16 digits");
        send_and_check("1234567890123456", 16, 1'b0);

        if (errors == 0) $display("ALL END-TO-END TESTS PASSED");
        else             $display("%0d END-TO-END TEST(S) FAILED", errors);
        $finish;
    end

    initial begin #3_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
