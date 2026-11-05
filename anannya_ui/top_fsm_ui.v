`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// top_fsm.v (Anannya) - message layer over uart_link, ONE BYTE PER CHARACTER
//  SEND:    send_req (1 clk) -> snapshot -> write bytes -> tx_send -> OK/FAIL
//  RECEIVE: a new type-0x10 packet replaces rx_log / rx_n
//  CRYPTO SLOT: ENCRYPT goes between the snapshot and S_LOAD,
//               DECRYPT goes after the receive read.
//////////////////////////////////////////////////////////////////////////////
module top_fsm #(
    parameter MAXLEN      = 16,
    parameter ACK_TIMEOUT = 3_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire loopback,                    // 1: our TX feeds our own RX
    input  wire rx_pin,
    output wire tx_pin,
    input  wire send_req,                    // 1-clock pulse
    input  wire [MAXLEN*8-1:0] msg_in,       // byte 0 = first character
    input  wire [4:0] msg_len_in,
    input  wire rx_clear,                    // 1-clock pulse
    output reg  send_ok,
    output reg  send_fail,
    output wire tx_busy,
    output reg  [MAXLEN*8-1:0] rx_log,       // received bytes, byte 0 in [7:0]
    output reg  [4:0] rx_n                   // how many bytes are valid
);
    localparam [7:0] T_DATA = 8'h10;
    localparam [4:0] MAXL   = MAXLEN;

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

    uart_link #(.ACK_TIMEOUT(ACK_TIMEOUT)) u_link (
        .clk(clk), .rst(rst), .rx_pin(link_rx), .tx_pin(link_tx),
        .tx_wr_en(l_we), .tx_wr_addr(l_wa), .tx_wr_data(l_wd),
        .tx_len(snap_len), .tx_type(T_DATA), .tx_send(l_send),
        .tx_busy(l_busy), .tx_done(l_done), .tx_fail(l_fail),
        .rx_rd_addr(ri), .rx_rd_data(l_rd), .rx_len(l_rlen),
        .rx_type(l_rtype), .rx_valid(l_rxv),
        .fault_inject(1'b0), .tick16_out(), .tx_seq(),
        .cnt_sent(), .cnt_recv(), .cnt_err(), .cnt_retry());

    //------------------------------------------------------------ sender FSM
    localparam S_IDLE = 2'd0, S_LOAD = 2'd1, S_WAIT = 2'd2;
    reg  [1:0] sst;
    reg  [MAXLEN*8-1:0] snap;
    reg  [4:0] widx;
    wire [4:0] n_in = (msg_len_in > MAXL) ? MAXL : msg_len_in;
    assign tx_busy = (sst != S_IDLE) | l_busy;

    always @(posedge clk) begin
        l_we   <= 1'b0;
        l_send <= 1'b0;
        if (rst) begin
            sst <= S_IDLE; snap <= 0; snap_len <= 8'd0; widx <= 5'd0;
            l_wa <= 7'd0; l_wd <= 8'd0; send_ok <= 1'b0; send_fail <= 1'b0;
        end else begin
            case (sst)
                S_IDLE: begin
                    if (send_req && msg_len_in != 5'd0 && !l_busy) begin   // empty is ignored
                        snap      <= msg_in;       // snapshot: editing can't change it now
                        snap_len  <= {3'd0, n_in};
                        widx      <= 5'd0;
                        send_ok   <= 1'b0;
                        send_fail <= 1'b0;
                        sst       <= S_LOAD;
                    end
                end
                S_LOAD: begin                      // one byte per clock
                    if (widx == snap_len[4:0]) begin
                        l_send <= 1'b1;
                        sst    <= S_WAIT;
                    end else begin
                        l_we   <= 1'b1;
                        l_wa   <= {2'b00, widx};
                        l_wd   <= snap[widx*8 +: 8];
                        widx   <= widx + 5'd1;
                    end
                end
                S_WAIT: begin                      // done/fail are 1-clock pulses
                    if (l_done) begin
                        send_ok <= 1'b1; send_fail <= 1'b0; sst <= S_IDLE;
                    end else if (l_fail) begin
                        send_ok <= 1'b0; send_fail <= 1'b1; sst <= S_IDLE;
                    end
                end
                default: sst <= S_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------ receiver FSM
    // l_rd is read combinationally from ri, so byte ri is valid in the same clock.
    reg       rstate;                              // 0 idle, 1 reading
    reg [4:0] rd_n;
    always @(posedge clk) begin
        if (rst) begin
            rstate <= 1'b0; ri <= 7'd0; rd_n <= 5'd0;
            rx_log <= 0; rx_n <= 5'd0;
        end else begin
            if (!rstate) begin
                if (l_rxv && l_rtype == T_DATA && l_rlen != 8'd0) begin
                    rstate <= 1'b1;
                    ri     <= 7'd0;
                    rd_n   <= (l_rlen > {3'd0, MAXL}) ? MAXL : l_rlen[4:0];
                end
            end else begin
                rx_log[ri*8 +: 8] <= l_rd;
                ri <= ri + 7'd1;
                if (ri[4:0] == rd_n - 5'd1) begin  // last byte: publish the count
                    rstate <= 1'b0;
                    rx_n   <= rd_n;
                end
            end
            if (rx_clear) begin                    // last, so it wins
                rx_log <= 0; rx_n <= 5'd0;
            end
        end
    end
endmodule