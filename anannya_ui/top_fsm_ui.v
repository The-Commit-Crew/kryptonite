`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// Message layer over one uart_link, with selectable Board 1 encryption.
//  SEND:    send_req (1 clk) -> snapshot msg -> write bytes -> tx_send -> OK/FAIL
//  RECEIVE: new short type-0x10 packet -> ASCII bytes in rx_log
//  ENCRYPT_SEND selects the encrypted sender. The default preserves plaintext.
//  Added by Khushi:
//   - link stats, fault inject and an rx_new pulse (7-segment, effects)
//   - an external sender port (ct_*): while ct_busy = 1 it owns uart_link's
//     TX side. Used by the ciphertext test sender in cipher_link.
//   - the RX buffer is shared with cipher_rx (ct_ra) when the text reader is
//     idle. Text messages are at most MAXLEN bytes, so 128-byte ciphertext
//     fragments are always left to cipher_rx.
//////////////////////////////////////////////////////////////////////////////
module top_fsm #(
    parameter MAXLEN      = 16,
    parameter ACK_TIMEOUT = 3_000_000,
    parameter ENCRYPT_SEND = 1'b0,
    parameter FIXED_NOISE = 1'b0,
    parameter KEY_DIR = "crypto/keys/board1",
    parameter NOISE_DIR = "crypto/test_vectors/noise",
    parameter BYTE_TMO = 100_000,
    parameter MAX_RETRY = 3,
    parameter [15:0] BAUD_INC = 16'd1208
)(
    input clk, rst,
    input loopback,                    // 1: our TX feeds our own RX
    input rx_pin, send_req,
    output tx_pin,                    // 1-clock pulse
    input  [MAXLEN*8-1:0] msg_in,       // ASCII byte 0 in [7:0]
    input [4:0] msg_len_in,
    input rx_clear,                    // 1-clock pulse
    output send_ok, send_fail,
    output tx_busy,
    output reg  [MAXLEN*8-1:0] rx_log,       // received bytes, byte 0 in [7:0]
    output reg  [4:0] rx_n,
    input retry_req,
    output wire mul_wr_en,
    output wire [7:0] mul_wr_addr,
    output wire [11:0] mul_left, mul_right,
    output wire mul_start,
    input wire mul_done,
    output wire [7:0] mul_rd_addr,
    input wire [11:0] mul_rd_data,
    // link stats and effects (Khushi)
    input  wire fault_inject,                // pulse: corrupt the next packet (demo)
    output reg  rx_new,                      // pulse: a new text message was unpacked
    output wire [11:0] cnt_sent, cnt_recv, cnt_err, cnt_retry,  // BCD link counters
    // external sender + shared RX buffer (Khushi, cipher_link)
    input  wire       ct_busy,               // external sender owns the link
    input  wire       ct_we,
    input  wire [6:0] ct_wa,
    input  wire [7:0] ct_wd,
    input  wire [7:0] ct_len,
    input  wire [7:0] ct_type,
    input  wire       ct_send,
    output wire       lk_busy, lk_done, lk_fail,
    input  wire [6:0] ct_ra,
    output wire       lk_rxv,
    output wire [7:0] lk_rtype, lk_rlen, lk_rd,
    // first 12 bytes of the last ciphertext sent (fragment 0), for display (Khushi)
    output reg  [95:0] tx_ct_head = 96'd0
);
    localparam [7:0] T_DATA = 8'h10;
    localparam [4:0] MAXL   = MAXLEN;

    // ---- declarations first (a name must exist before it is used) ----
    wire link_tx;
    wire link_rx = loopback ? link_tx : rx_pin;
    assign tx_pin = link_tx;

    reg        l_we, l_send;
    reg  [6:0] l_wa;
    reg  [7:0] l_wd;
    reg  [7:0] snap_len;
    reg  [6:0] ri;
    wire       l_busy, l_done, l_fail, l_rxv;
    wire [7:0] l_rd, l_rlen, l_rtype;
    wire c_we, c_send, c_busy, c_ok, c_fail;
    wire [6:0] c_wa;
    wire [7:0] c_wd, c_len, c_type;
    reg legacy_ok, legacy_fail;
    reg rstate;                                        // receiver: 0 idle, 1 reading

    // who drives uart_link's TX side: external sender, encrypted sender or plaintext
    wire       m_we   = ct_busy ? ct_we   : (ENCRYPT_SEND ? c_we   : l_we);
    wire [6:0] m_wa   = ct_busy ? ct_wa   : (ENCRYPT_SEND ? c_wa   : l_wa);
    wire [7:0] m_wd   = ct_busy ? ct_wd   : (ENCRYPT_SEND ? c_wd   : l_wd);
    wire [7:0] m_len  = ct_busy ? ct_len  : (ENCRYPT_SEND ? c_len  : snap_len);
    wire [7:0] m_type = ct_busy ? ct_type : (ENCRYPT_SEND ? c_type : T_DATA);
    wire       m_send = ct_busy ? ct_send : (ENCRYPT_SEND ? c_send : l_send);

    uart_link #(.ACK_TIMEOUT(ACK_TIMEOUT), .BYTE_TMO(BYTE_TMO),
                .MAX_RETRY(MAX_RETRY), .BAUD_INC(BAUD_INC)) u_link (
        .clk(clk), .rst(rst), .rx_pin(link_rx), .tx_pin(link_tx),
        .tx_wr_en(m_we), .tx_wr_addr(m_wa), .tx_wr_data(m_wd), .tx_len(m_len),
        .tx_type(m_type), .tx_send(m_send),
        .tx_busy(l_busy), .tx_done(l_done), .tx_fail(l_fail),
        .rx_rd_addr(rstate ? ri : ct_ra), .rx_rd_data(l_rd), .rx_len(l_rlen),
        .rx_type(l_rtype), .rx_valid(l_rxv),
        .fault_inject(fault_inject), .tick16_out(), .tx_seq(),
        .cnt_sent(cnt_sent), .cnt_recv(cnt_recv), .cnt_err(cnt_err), .cnt_retry(cnt_retry));

    // snoop the TX buffer while ciphertext fragment 0 is being written
    always @(posedge clk)
        if (m_we && m_type == 8'h10 && m_len == 8'd128 && m_wa < 7'd12)
            tx_ct_head[m_wa * 8 +: 8] <= m_wd;

    assign lk_busy = l_busy;
    assign lk_done = l_done & ct_busy;                 // only the external sender's results
    assign lk_fail = l_fail & ct_busy;
    assign lk_rxv   = l_rxv;
    assign lk_rtype = l_rtype;
    assign lk_rlen  = l_rlen;
    assign lk_rd    = l_rd;

    //------------------------------------------------------------ sender FSM
    localparam S_IDLE = 2'd0, S_LOAD = 2'd1, S_WAIT = 2'd2;
    reg  [1:0] sst;
    reg  [MAXLEN*8-1:0] snap;
    reg  [4:0] widx;
    wire [4:0] n_in = (msg_len_in > MAXL) ? MAXL : msg_len_in;
    assign tx_busy = (ENCRYPT_SEND ? c_busy : ((sst != S_IDLE) | l_busy)) | ct_busy;
    assign send_ok = ENCRYPT_SEND ? c_ok : legacy_ok;
    assign send_fail = ENCRYPT_SEND ? c_fail : legacy_fail;

    generate if (ENCRYPT_SEND) begin : encrypted_tx
        board1_message_tx #(.FIXED_NOISE(FIXED_NOISE), .KEY_DIR(KEY_DIR), .NOISE_DIR(NOISE_DIR)) sender (
            .clk(clk), .rst(rst), .send_req(send_req), .retry_req(retry_req),
            .msg_in(msg_in), .msg_len_in(n_in), .busy(c_busy), .send_ok(c_ok), .send_fail(c_fail),
            .tx_wr_en(c_we), .tx_wr_addr(c_wa), .tx_wr_data(c_wd), .tx_len(c_len),
            .tx_type(c_type), .tx_send(c_send), .tx_busy(l_busy), .tx_done(l_done), .tx_fail(l_fail),
            .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr), .mul_left(mul_left),
            .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
            .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data)
        );
    end else begin : plaintext_tx
    assign mul_wr_en = 0;
    assign mul_wr_addr = 0;
    assign mul_left = 0;
    assign mul_right = 0;
    assign mul_start = 0;
    assign mul_rd_addr = 0;
    always @(posedge clk) begin
        l_we   <= 1'b0;
        l_send <= 1'b0;
        if (rst) begin
            sst <= S_IDLE; snap <= 0; snap_len <= 8'd0; widx <= 5'd0;
            l_wa <= 7'd0; l_wd <= 8'd0; legacy_ok <= 1'b0; legacy_fail <= 1'b0;
        end else begin
            case (sst)
                S_IDLE: begin
                    // an empty message is ignored
                    if (send_req && msg_len_in != 5'd0 && !l_busy && !ct_busy) begin
                        snap      <= msg_in;           // snapshot: editing can't change it now
                        snap_len  <= {3'd0, n_in};
                        widx      <= 5'd0;
                        legacy_ok   <= 1'b0;
                        legacy_fail <= 1'b0;
                        sst       <= S_LOAD;
                    end
                end
                S_LOAD: begin                          // one byte per clock
                    if (widx == snap_len[4:0]) begin
                        l_send <= 1'b1;                // last write is already stored
                        sst    <= S_WAIT;
                    end else begin
                        l_we   <= 1'b1;
                        l_wa   <= {2'b00, widx};
                        l_wd   <= snap[widx*8 +: 8];
                        widx   <= widx + 5'd1;
                    end
                end
                S_WAIT: begin                          // done/fail are 1-clock pulses
                    if (l_done) begin
                        legacy_ok <= 1'b1; legacy_fail <= 1'b0; sst <= S_IDLE;
                    end else if (l_fail) begin
                        legacy_ok <= 1'b0; legacy_fail <= 1'b1; sst <= S_IDLE;
                    end
                end
                default: sst <= S_IDLE;
            endcase
        end
    end

    end endgenerate

    //------------------------------------------------------------ receiver FSM
    // l_rd is read combinationally from ri, so byte ri is valid in the same clock.
    reg [4:0] rd_n;
    always @(posedge clk) begin
        rx_new <= 1'b0;
        if (rst) begin
            rstate <= 1'b0; ri <= 7'd0; rd_n <= 5'd0;
            rx_log <= 0; rx_n <= 5'd0;
        end else begin
            if (!rstate) begin
                // Full ciphertext fragments belong to the Board 2 reassembler.
                if (l_rxv && l_rtype == T_DATA && l_rlen != 8'd0 &&
                    l_rlen <= {3'd0, MAXL}) begin
                    rstate <= 1'b1;
                    ri     <= 7'd0;
                    rd_n   <= (l_rlen > {3'd0, MAXL}) ? MAXL : l_rlen[4:0];
                end
            end else begin
                rx_log[ri*8 +: 8] <= l_rd;
                ri <= ri + 7'd1;
                if (ri[4:0] == rd_n - 5'd1) begin      // last byte: publish the counts
                    rstate   <= 1'b0;
                    rx_n     <= rd_n;
                    rx_new   <= 1'b1;
                end
            end
            if (rx_clear) begin                        // last, so it wins
                rx_log <= 0; rx_n <= 5'd0;
            end
        end
    end
endmodule
