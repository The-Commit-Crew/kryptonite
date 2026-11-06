`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// rx_decrypt.v  (Khushi) - Board 2: decrypt the received ciphertext and turn
// it back into the message the RX screen shows
//
//   start (ciphertext rebuilt and checked) -> decryption_ntt (Divyansh) reads
//   u0, u1, v straight out of cipher_rx's RAM -> 256 message bits
//   -> bytes: byte i = msg_bits[8i +: 8]   (same packing as board1_send)
//   -> msg_log / msg_n in the same layout as top_fsm's rx_log / rx_n
//      (byte k at msg_log[8k +: 8], at most 16 characters)
//
// board1_send pads the message with spaces, so trailing spaces (and zero
// bytes) are dropped from the length, and bytes past the length are cleared
// to 0 like top_fsm's rx_log. Takes about 34,000 clocks (0.34 ms).
//////////////////////////////////////////////////////////////////////////////
module rx_decrypt #(
    parameter MAXLEN = 16
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,          // pulse: a new ciphertext is ready
    output wire [9:0]         ct_addr,        // to cipher_rx's read port
    input  wire [11:0]        ct_data,
    output wire               busy,
    output reg                msg_new,        // pulse: msg_log / msg_n updated
    output reg  [MAXLEN*8-1:0] msg_log,
    output reg  [4:0]         msg_n
);
    wire         dec_done;
    wire [255:0] msg_bits;

    decryption_ntt #(.EXT_CT(1), .PIPELINED(1)) u_dec (
        .clk(clk), .rst(rst), .start(start), .done(dec_done),
        .msg_bits(msg_bits), .ct_addr(ct_addr), .ct_data(ct_data));

    reg running, done_q;
    assign busy = running;

    // message length: the last character that is not padding, plus one
    function [4:0] text_len;
        input [MAXLEN*8-1:0] t;
        integer i;
        begin
            text_len = 5'd0;
            for (i = 0; i < MAXLEN; i = i + 1)
                if (t[8*i +: 8] != 8'h20 && t[8*i +: 8] != 8'h00) text_len = i + 1;
        end
    endfunction

    // keep only the first n bytes
    function [MAXLEN*8-1:0] keep;
        input [MAXLEN*8-1:0] t;
        input [4:0] n;
        integer i;
        begin
            keep = 0;
            for (i = 0; i < MAXLEN; i = i + 1)
                if (i < n) keep[8*i +: 8] = t[8*i +: 8];
        end
    endfunction
    wire [MAXLEN*8-1:0] raw = msg_bits[MAXLEN*8-1:0];
    wire [4:0]          raw_n = text_len(raw);

    always @(posedge clk) begin
        msg_new <= 1'b0;
        done_q  <= dec_done;
        if (rst) begin
            running <= 1'b0; msg_log <= 0; msg_n <= 5'd0; done_q <= 1'b0;
        end else begin
            if (start) running <= 1'b1;
            if (running && dec_done && !done_q && !start) begin
                running <= 1'b0;
                msg_log <= keep(raw, raw_n);
                msg_n   <= raw_n;
                msg_new <= 1'b1;
            end
        end
    end
endmodule
