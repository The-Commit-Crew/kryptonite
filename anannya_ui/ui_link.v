`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 07:36:06 PM
// Design Name: 
// Module Name: ui_link
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////
// ui_link.v  (Anannya) - UI side of the UART link
//  SEND: send_pulse (1 clk) + send_byte -> 1-byte packet, type 0x10
//  RECV: every new type-0x10 packet is appended to rx_log (max LOGN bytes)
//  loopback = 1: our TX wire feeds our own RX (one-board test)
//////////////////////////////////////////////////////////////////////////////
module ui_link #(
    parameter LOGN = 16
)(
    input  wire clk,
    input  wire rst,
    input  wire send_pulse,
    input  wire [7:0] send_byte,
    input  wire rx_clear,
    input  wire loopback,
    input  wire rx_pin,
    output wire tx_pin,
    output reg  send_ok,                    // last send was ACKed
    output reg  send_fail,                  // last send gave up
    output reg  [LOGN*8-1:0] rx_log,        // received bytes, byte 0 in [7:0]
    output reg  [4:0] rx_n,                 // how many bytes are in rx_log
    output wire tx_busy
);
    localparam [7:0] T_DATA = 8'h10;

    wire link_tx;
    wire link_rx = loopback ? link_tx : rx_pin;
    assign tx_pin = link_tx;

    reg        l_we, l_send;
    reg  [7:0] l_wd;
    wire       l_done, l_fail, l_rxv;
    wire [7:0] l_rd, l_rlen, l_rtype;
    reg  [7:0] rd_i;
    wire [6:0] l_ra = rd_i[6:0];

    uart_link u_link (
        .clk(clk), .rst(rst), .rx_pin(link_rx), .tx_pin(link_tx),
        .tx_wr_en(l_we), .tx_wr_addr(7'd0), .tx_wr_data(l_wd),
        .tx_len(8'd1), .tx_type(T_DATA), .tx_send(l_send),
        .tx_busy(tx_busy), .tx_done(l_done), .tx_fail(l_fail),
        .rx_rd_addr(l_ra), .rx_rd_data(l_rd), .rx_len(l_rlen),
        .rx_type(l_rtype), .rx_valid(l_rxv),
        .fault_inject(1'b0), .tick16_out(), .tx_seq(),
        .cnt_sent(), .cnt_recv(), .cnt_err(), .cnt_retry());

    //------------------------------------------------------------ sender
    // send_pulse lasts ONE clock, so we remember it (pending + pbyte).
    // sst 0: when idle, write the byte into the TX buffer (address 0)
    // sst 1: one clock later the byte is stored, so pulse tx_send
    reg       pending;
    reg [7:0] pbyte;
    reg       sst;
    always @(posedge clk) begin
        l_we   <= 1'b0;
        l_send <= 1'b0;
        if (rst) begin
            pending <= 1'b0; pbyte <= 8'd0; sst <= 1'b0;
            l_wd <= 8'd0; send_ok <= 1'b0; send_fail <= 1'b0;
        end else begin
            if (l_done)      begin send_ok <= 1'b1; send_fail <= 1'b0; end
            else if (l_fail) begin send_ok <= 1'b0; send_fail <= 1'b1; end

            if (!sst) begin
                if (pending && !tx_busy) begin
                    l_we      <= 1'b1;
                    l_wd      <= pbyte;
                    pending   <= 1'b0;
                    send_ok   <= 1'b0;          // new send: forget old result
                    send_fail <= 1'b0;
                    sst       <= 1'b1;
                end
            end else begin
                l_send <= 1'b1;
                sst    <= 1'b0;
            end

            // last, so a new request is never lost
            if (send_pulse) begin pending <= 1'b1; pbyte <= send_byte; end
        end
    end

    //------------------------------------------------------------ receiver
    // l_rd is read combinationally from l_ra, so byte i is valid in the
    // same clock that rd_i == i. No wait state needed.
    reg       reading;
    reg [7:0] rd_n;
    always @(posedge clk) begin
        if (rst) begin
            reading <= 1'b0; rd_i <= 8'd0; rd_n <= 8'd0;
            rx_log <= 0; rx_n <= 5'd0;
        end else begin
            if (!reading) begin
                if (l_rxv && l_rtype == T_DATA && l_rlen != 8'd0) begin
                    reading <= 1'b1;
                    rd_i    <= 8'd0;
                    rd_n    <= l_rlen;
                end
            end else begin
                if (rx_n < LOGN) begin
                    rx_log[rx_n*8 +: 8] <= l_rd;
                    rx_n <= rx_n + 5'd1;
                end
                rd_i <= rd_i + 8'd1;
                if (rd_i == rd_n - 8'd1) reading <= 1'b0;
            end
            if (rx_clear) begin rx_log <= 0; rx_n <= 5'd0; end
        end
    end
endmodule