`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// cipher_link.v  (Khushi) - ciphertext receive path + a test sender
//
//   receive (Board 2): uart_link -> cipher_rx (768-word RAM) -> ct_check,
//                      which compares it with the known test vector, then
//                      rx_decrypt (Divyansh's decryption_ntt) -> the message
//   test send:         ct_source -> ciphertext_uart_tx (Shrikkanth's sender,
//                      same 12 x 128-byte packets as real encryption) -> link
//
// The test sender lets the whole UART path be tested on the board before
// the polynomial multiplier exists: send with test mode on, and the other
// board (or the same board in loopback) should report PASS.
//
// Every complete ciphertext is decrypted (test vector or a real encrypted
// send). msg_new pulses when msg_log / msg_n hold the decrypted message.
//////////////////////////////////////////////////////////////////////////////
module cipher_link (
    input  wire        clk,
    input  wire        rst,
    input  wire        test_send,        // pulse: send the test ciphertext
    input  wire        clear,            // pulse: forget the received one

    // status
    output reg         tx_ok,            // last test send: all 12 delivered
    output reg         tx_bad,           // last test send: gave up on a packet
    output wire [11:0] rx_mask,          // fragments received
    output wire        ct_ready,         // all 12 received
    output wire        ct_new,           // pulse: a complete ciphertext arrived
    output wire [71:0] ct_head,          // its first 6 coefficients, for display
    output wire        chk_pass,         // received copy == test vector
    output wire        chk_fail,
    output wire [9:0]  chk_mismatch,

    // decrypted message (same layout as top_fsm's rx_log / rx_n)
    output wire        dec_busy,
    output wire        msg_new,
    output wire [127:0] msg_log,
    output wire [4:0]  msg_n,

    // to top_fsm
    output wire        ct_busy,
    output wire        ct_we,
    output wire [6:0]  ct_wa,
    output wire [7:0]  ct_wd,
    output wire [7:0]  ct_len,
    output wire [7:0]  ct_type,
    output wire        ct_send,
    input  wire        lk_busy, lk_done, lk_fail,
    output wire [6:0]  ct_ra,
    input  wire        lk_rxv,
    input  wire [7:0]  lk_rtype, lk_rlen, lk_rd
);
    wire [9:0]  src_addr, chk_addr;
    wire [11:0] src_data, want, rx_data;
    wire        done, fail, chk_run;

    ct_source u_src (.clk(clk), .addr_a(src_addr), .data_a(src_data),
                     .addr_b(chk_addr), .data_b(want));

    ciphertext_uart_tx u_tx (
        .clk(clk), .rst(rst), .start(test_send), .busy(ct_busy), .done(done), .fail(fail),
        .ciphertext_addr(src_addr), .ciphertext_data(src_data),
        .tx_wr_en(ct_we), .tx_wr_addr(ct_wa), .tx_wr_data(ct_wd), .tx_len(ct_len),
        .tx_type(ct_type), .tx_send(ct_send),
        .tx_busy(lk_busy), .tx_done(lk_done), .tx_fail(lk_fail));

    always @(posedge clk) begin
        if (rst || test_send) begin tx_ok <= 1'b0; tx_bad <= 1'b0; end
        else begin
            if (done) tx_ok  <= 1'b1;
            if (fail) tx_bad <= 1'b1;
        end
    end

    // the check owns the RAM read port while it runs, the decryptor after it
    wire [9:0] dec_addr;
    wire [9:0] rd_addr = chk_run ? chk_addr : dec_addr;
    cipher_rx u_rx (
        .clk(clk), .rst(rst), .clear(clear),
        .lk_rxv(lk_rxv), .lk_rtype(lk_rtype), .lk_rlen(lk_rlen),
        .lk_ra(ct_ra), .lk_rd(lk_rd),
        .got_mask(rx_mask), .ready(ct_ready), .new_ct(ct_new), .head(ct_head),
        .rd_addr(rd_addr), .rd_data(rx_data));

    // start decrypting as soon as the check has finished with the RAM
    reg chk_run_q;
    always @(posedge clk) chk_run_q <= rst ? 1'b0 : chk_run;
    wire dec_start = chk_run_q && !chk_run;

    rx_decrypt u_dec (
        .clk(clk), .rst(rst | clear), .start(dec_start),
        .ct_addr(dec_addr), .ct_data(rx_data), .busy(dec_busy),
        .msg_new(msg_new), .msg_log(msg_log), .msg_n(msg_n));

    ct_check u_chk (
        .clk(clk), .rst(rst | clear), .start(ct_new), .addr(chk_addr),
        .got(rx_data), .want(want), .running(chk_run),
        .pass(chk_pass), .fail(chk_fail), .mismatches(chk_mismatch));
endmodule
