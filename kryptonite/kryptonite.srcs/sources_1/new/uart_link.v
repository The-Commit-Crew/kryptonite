`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_link.v  (Khushi)
//
// Reliable board-to-board link. Both boards use this same module.
//
//   uart_rx -> FIFO -> pkt_rx ---> [checks] ---> RX buffer -> decryptor
//                                     |
//   encryptor -> TX buffer -> pkt_tx -+-> uart_tx -> wire
//
// RELIABILITY (stop-and-wait ARQ):
//  * Sender: sends DATA with sequence number SEQ, then waits for a reply.
//      ACK with the same SEQ  -> success, SEQ = SEQ + 1
//      NAK, or no reply within ACK_TIMEOUT -> send again (up to MAX_RETRY
//      extra tries), then give up (tx_fail) and move on to SEQ + 1.
//  * Receiver: checks the checksum.
//      bad  -> reply NAK, count an error, discard
//      good -> reply ACK. If SEQ is the same as the last delivered packet,
//              it's a re-send because our ACK got lost: ACK it again but do
//              NOT deliver it twice. Otherwise copy it into the RX buffer
//              and pulse rx_valid.
//
// FAULT INJECTION (demo): a pulse on fault_inject makes the NEXT data packet
// leave with a broken checksum. The other side NAKs it, we re-send, and it
// arrives correctly. The stats on the 7-segment show 1 error, 1 retry.
//
// STATS (3-digit BCD counters, 0..999, shown by seg7_stats.v):
//   cnt_sent   data packets delivered (ACKed)
//   cnt_recv   new data packets received
//   cnt_err    bad checksums + timeouts + bad lengths + FIFO overflows
//   cnt_retry  re-sends
//
// Interface for teammates:
//   SEND (Shrikkanth): write bytes with tx_wr_en/addr/data, set tx_len and
//     tx_type (0x10 = ciphertext), pulse tx_send when tx_busy = 0.
//     Wait for tx_done (delivered) or tx_fail (gave up).
//   RECEIVE (Divyansh): on rx_valid, rx_len / rx_type are valid and bytes
//     can be read from rx_rd_addr -> rx_rd_data. The RX buffer only changes
//     when the next NEW packet is delivered.
//////////////////////////////////////////////////////////////////////////////
module uart_link #(
    parameter AW          = 7,            // buffers hold 2^AW = 128 bytes
    parameter MAX_LEN     = 128,
    parameter BYTE_TMO    = 100_000,      // 1 ms gap inside a packet = abandon
    parameter ACK_TIMEOUT = 3_000_000,    // 30 ms with no reply = re-send
    parameter MAX_RETRY   = 3,
    parameter [15:0] BAUD_INC = 16'd1208  // 115200 baud at 100 MHz
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          rx_pin,
    output wire          tx_pin,

    // send side
    input  wire          tx_wr_en,
    input  wire [AW-1:0] tx_wr_addr,
    input  wire [7:0]    tx_wr_data,
    input  wire [7:0]    tx_len,
    input  wire [7:0]    tx_type,
    input  wire          tx_send,
    output wire          tx_busy,
    output reg           tx_done,
    output reg           tx_fail,

    // receive side
    input  wire [AW-1:0] rx_rd_addr,
    output wire [7:0]    rx_rd_data,
    output reg  [7:0]    rx_len,
    output reg  [7:0]    rx_type,
    output reg           rx_valid,

    // demo / status
    input  wire          fault_inject,
    output wire          tick16_out,      // shared with other UARTs (grid dump)
    output reg  [7:0]    tx_seq,
    output reg  [11:0]   cnt_sent,
    output reg  [11:0]   cnt_recv,
    output reg  [11:0]   cnt_err,
    output reg  [11:0]   cnt_retry
);
    localparam T_ACK = 8'h02, T_NAK = 8'h03;

    //=========================================================== byte layer
    wire tick16;
    assign tick16_out = tick16;
    baud_gen #(.INC(BAUD_INC)) u_baud (.clk(clk), .rst(rst), .tick16(tick16));

    wire [7:0] u_tx_data;
    wire       u_tx_start, u_tx_ready, u_tx_done;
    uart_tx u_utx (.clk(clk), .rst(rst), .tick16(tick16),
                   .data(u_tx_data), .start(u_tx_start),
                   .tx(tx_pin), .ready(u_tx_ready), .done(u_tx_done));

    wire [7:0] u_rx_data;
    wire       u_rx_valid, u_rx_ferr;
    uart_rx u_urx (.clk(clk), .rst(rst), .tick16(tick16), .rx(rx_pin),
                   .data(u_rx_data), .valid(u_rx_valid), .frame_err(u_rx_ferr));

    wire [7:0] f_dout;
    wire       f_empty, f_full, f_ovf, f_pop;
    sync_fifo #(.WIDTH(8), .AW(4)) u_fifo (
        .clk(clk), .rst(rst), .push(u_rx_valid), .din(u_rx_data),
        .pop(f_pop), .dout(f_dout), .empty(f_empty), .full(f_full),
        .overflow(f_ovf));

    //=========================================================== buffers
    reg [7:0] tx_buf  [0:(1<<AW)-1];      // written by the encryptor
    reg [7:0] stg_buf [0:(1<<AW)-1];      // packet being received
    reg [7:0] rx_buf  [0:(1<<AW)-1];      // last delivered packet

    always @(posedge clk)
        if (tx_wr_en) tx_buf[tx_wr_addr] <= tx_wr_data;

    assign rx_rd_data = rx_buf[rx_rd_addr];

    //=========================================================== packet layer
    wire [AW-1:0] ptx_rd_addr;
    reg           ptx_start;
    reg  [7:0]    ptx_type, ptx_seq, ptx_len;
    reg           ptx_corrupt;
    wire          ptx_busy, ptx_done;
    pkt_tx #(.AW(AW)) u_ptx (
        .clk(clk), .rst(rst),
        .start(ptx_start), .type_in(ptx_type), .seq_in(ptx_seq),
        .len_in(ptx_len), .corrupt(ptx_corrupt),
        .rd_addr(ptx_rd_addr), .rd_data(tx_buf[ptx_rd_addr]),
        .tx_data(u_tx_data), .tx_start(u_tx_start),
        .tx_ready(u_tx_ready), .tx_done(u_tx_done),
        .busy(ptx_busy), .done(ptx_done));

    wire          prx_we;
    wire [AW-1:0] prx_addr;
    wire [7:0]    prx_din;
    wire          prx_done, prx_ok, prx_tmo, prx_badlen;
    wire [7:0]    prx_type, prx_seq, prx_len;
    pkt_rx #(.AW(AW), .MAX_LEN(MAX_LEN), .TIMEOUT(BYTE_TMO)) u_prx (
        .clk(clk), .rst(rst),
        .in_data(f_dout), .in_avail(~f_empty), .in_pop(f_pop),
        .buf_we(prx_we), .buf_addr(prx_addr), .buf_din(prx_din),
        .done(prx_done), .ok(prx_ok), .pkt_type(prx_type),
        .pkt_seq(prx_seq), .pkt_len(prx_len),
        .timeout(prx_tmo), .bad_len(prx_badlen));

    always @(posedge clk)
        if (prx_we) stg_buf[prx_addr] <= prx_din;

    //=========================================================== BCD helper
    // add 1 to a 3-digit BCD number, stop at 999
    function [11:0] bcd_inc;
        input [11:0] v;
        begin
            if (v == 12'h999)               bcd_inc = v;
            else if (v[3:0] != 4'd9)        bcd_inc = v + 12'h001;
            else if (v[7:4] != 4'd9)        bcd_inc = {v[11:8], v[7:4] + 4'd1, 4'd0};
            else                            bcd_inc = {v[11:8] + 4'd1, 8'h00};
        end
    endfunction

    //=========================================================== receiver
    reg        ctl_pending;               // an ACK/NAK waiting to be sent
    reg [7:0]  ctl_type, ctl_seq;
    reg        have_last;
    reg [7:0]  last_seq;
    reg        copying;
    reg [7:0]  copy_idx, copy_len;
    reg [7:0]  copy_type;

    // events for the sender FSM
    wire got_ack = prx_done & prx_ok & (prx_type == T_ACK);
    wire got_nak = prx_done & prx_ok & (prx_type == T_NAK);
    wire is_data = (prx_type >= 8'h10);

    //=========================================================== sender
    localparam L_IDLE = 2'd0, L_SEND = 2'd1, L_WAITTX = 2'd2, L_WAITACK = 2'd3;
    reg [1:0]  lstate;
    reg        send_req;
    reg        inject_pending;
    reg [7:0]  cur_len, cur_type;
    reg [2:0]  attempts;
    reg [24:0] ack_timer;
    reg        ptx_owner_data;            // 1 = pkt_tx is sending our DATA

    assign tx_busy = send_req | (lstate != L_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            ctl_pending <= 0; ctl_type <= 0; ctl_seq <= 0;
            have_last <= 0; last_seq <= 0;
            copying <= 0; copy_idx <= 0; copy_len <= 0; copy_type <= 0;
            rx_valid <= 0; rx_len <= 0; rx_type <= 0;
            lstate <= L_IDLE; send_req <= 0; inject_pending <= 0;
            cur_len <= 0; cur_type <= 0; attempts <= 0; ack_timer <= 0;
            ptx_start <= 0; ptx_type <= 0; ptx_seq <= 0; ptx_len <= 0;
            ptx_corrupt <= 0; ptx_owner_data <= 0;
            tx_seq <= 0; tx_done <= 0; tx_fail <= 0;
            cnt_sent <= 0; cnt_recv <= 0; cnt_err <= 0; cnt_retry <= 0;
        end else begin
            rx_valid  <= 1'b0;
            tx_done   <= 1'b0;
            tx_fail   <= 1'b0;
            ptx_start <= 1'b0;

            if (fault_inject) inject_pending <= 1'b1;
            if (tx_send && lstate == L_IDLE && !send_req) begin
                send_req <= 1'b1;
                cur_len  <= tx_len;
                cur_type <= tx_type;
            end

            //---------------------------------------------- error counting
            if ((prx_done && !prx_ok) || prx_tmo || prx_badlen || f_ovf)
                cnt_err <= bcd_inc(cnt_err);

            //---------------------------------------------- receive decisions
            if (prx_done && is_data) begin
                ctl_pending <= 1'b1;
                ctl_seq     <= prx_seq;
                if (!prx_ok) begin
                    ctl_type <= T_NAK;
                end else begin
                    ctl_type <= T_ACK;
                    if (!have_last || prx_seq != last_seq) begin
                        have_last <= 1'b1;
                        last_seq  <= prx_seq;
                        copying   <= 1'b1;
                        copy_idx  <= 0;
                        copy_len  <= prx_len;
                        copy_type <= prx_type;
                    end
                end
            end

            // copy staging -> rx buffer, one byte per clock, then announce
            if (copying) begin
                if (copy_idx == copy_len) begin
                    copying  <= 1'b0;
                    rx_len   <= copy_len;
                    rx_type  <= copy_type;
                    rx_valid <= 1'b1;
                    cnt_recv <= bcd_inc(cnt_recv);
                end else begin
                    copy_idx <= copy_idx + 8'd1;
                end
            end

            //---------------------------------------------- transmit arbitration
            // ACK/NAK replies go first, they are short and the other side is waiting
            if (!ptx_busy && !ptx_start) begin
                if (ctl_pending && !(prx_done && is_data)) begin
                    ctl_pending    <= 1'b0;
                    ptx_type       <= ctl_type;
                    ptx_seq        <= ctl_seq;
                    ptx_len        <= 8'd0;
                    ptx_corrupt    <= 1'b0;
                    ptx_start      <= 1'b1;
                    ptx_owner_data <= 1'b0;
                end else if (lstate == L_SEND) begin
                    ptx_type       <= cur_type;
                    ptx_seq        <= tx_seq;
                    ptx_len        <= cur_len;
                    ptx_corrupt    <= inject_pending;
                    inject_pending <= 1'b0;
                    ptx_start      <= 1'b1;
                    ptx_owner_data <= 1'b1;
                    lstate         <= L_WAITTX;
                end
            end

            //---------------------------------------------- sender FSM
            case (lstate)
            L_IDLE: if (send_req) begin
                send_req <= 1'b0;
                attempts <= 0;
                lstate   <= L_SEND;
            end
            L_SEND: ;   // handled by the arbitration above
            L_WAITTX: if (ptx_done && ptx_owner_data) begin
                ack_timer <= 0;
                lstate    <= L_WAITACK;
            end
            L_WAITACK: begin
                ack_timer <= ack_timer + 25'd1;
                if (got_ack && prx_seq == tx_seq) begin
                    tx_seq   <= tx_seq + 8'd1;          // next sequence number
                    cnt_sent <= bcd_inc(cnt_sent);
                    tx_done  <= 1'b1;
                    lstate   <= L_IDLE;
                end else if ((got_nak && prx_seq == tx_seq) || ack_timer == ACK_TIMEOUT - 1) begin
                    if (attempts < MAX_RETRY) begin
                        attempts  <= attempts + 3'd1;
                        cnt_retry <= bcd_inc(cnt_retry);
                        lstate    <= L_SEND;
                    end else begin
                        tx_seq  <= tx_seq + 8'd1;       // move on so the next
                        tx_fail <= 1'b1;                // message isn't mistaken
                        lstate  <= L_IDLE;              // for a duplicate
                    end
                end
            end
            endcase
        end
    end

    // staging -> rx buffer copy (separate block so it maps to simple RAM)
    always @(posedge clk)
        if (copying && copy_idx != copy_len)
            rx_buf[copy_idx[AW-1:0]] <= stg_buf[copy_idx[AW-1:0]];
endmodule
