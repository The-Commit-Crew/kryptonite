`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// cipher_link.v  (Khushi) - ciphertext receive path + a test sender
//
//   receive (Board 2): uart_link -> cipher_rx (768-word RAM) -> decryptor
//                      and ct_check, which compares the result with the
//                      known test vector (ct_source)
//   test send:         ct_source -> ciphertext_uart_tx (Shrikkanth's sender,
//                      same 12 x 128-byte packets as real encryption) -> link
//
// The test sender lets the whole UART path be tested on the board before
// the polynomial multiplier exists: send with test mode on, and the other
// board (or the same board in loopback) should report PASS.
//
// Decryptor (Divyansh): once ct_ready = 1, read word dec_addr on dec_data one
// clock later (0..255 u0, 256..511 u1, 512..767 v). ct_new pulses when a new
// complete ciphertext is in.
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
    output wire        chk_pass,         // received copy == test vector
    output wire        chk_fail,
    output wire [9:0]  chk_mismatch,

    // decryptor read port (Divyansh)
    input  wire [9:0]  dec_addr,
    output wire [11:0] dec_data,

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

    // the check owns the RAM read port while it runs, the decryptor otherwise
    wire [9:0] rd_addr = chk_run ? chk_addr : dec_addr;
    cipher_rx u_rx (
        .clk(clk), .rst(rst), .clear(clear),
        .lk_rxv(lk_rxv), .lk_rtype(lk_rtype), .lk_rlen(lk_rlen),
        .lk_ra(ct_ra), .lk_rd(lk_rd),
        .got_mask(rx_mask), .ready(ct_ready), .new_ct(ct_new),
        .rd_addr(rd_addr), .rd_data(rx_data));
    assign dec_data = rx_data;

    ct_check u_chk (
        .clk(clk), .rst(rst | clear), .start(ct_new), .addr(chk_addr),
        .got(rx_data), .want(want), .running(chk_run),
        .pass(chk_pass), .fail(chk_fail), .mismatches(chk_mismatch));
endmodule
