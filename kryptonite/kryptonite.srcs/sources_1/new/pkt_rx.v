`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// pkt_rx.v  (Khushi)
//
// Reads bytes from the receive FIFO and rebuilds packets (format in pkt_tx.v).
//
//   HUNT    throw bytes away until 0x7E (start of frame) is seen
//   TYPE, SEQ, LEN, PAYLOAD x LEN, CHK
//
// While reading it adds up every byte after 0x7E. If the total including
// CHK is 0, the packet arrived intact (ok = 1). Otherwise a byte was
// corrupted on the wire (ok = 0).
//
// Inter-byte timeout: if the packet stops arriving halfway (cable pulled,
// other board reset), no byte comes for TIMEOUT clocks and we give up on
// this packet and go back to HUNT, instead of waiting forever. One byte
// takes 87 us at 115200 baud, so 1 ms of silence clearly means trouble.
//
// Payload bytes are written into a buffer (buf_we / buf_addr / buf_din).
//////////////////////////////////////////////////////////////////////////////
module pkt_rx #(
    parameter AW      = 7,               // payload buffer address width
    parameter MAX_LEN = 128,
    parameter TIMEOUT = 100_000          // 1 ms at 100 MHz
)(
    input  wire          clk,
    input  wire          rst,

    // from the FIFO
    input  wire [7:0]    in_data,
    input  wire          in_avail,       // FIFO not empty
    output wire          in_pop,

    // payload buffer write port
    output reg           buf_we,
    output reg  [AW-1:0] buf_addr,
    output reg  [7:0]    buf_din,

    // result
    output reg           done,           // pulse: a whole packet was read
    output reg           ok,             // checksum good (valid with done)
    output reg  [7:0]    pkt_type,
    output reg  [7:0]    pkt_seq,
    output reg  [7:0]    pkt_len,
    output reg           timeout,        // pulse: packet abandoned
    output reg           bad_len         // pulse: LEN too big, packet dropped
);
    localparam SOF = 8'h7E;
    localparam S_HUNT = 3'd0, S_TYPE = 3'd1, S_SEQ = 3'd2, S_LEN = 3'd3,
               S_PAY  = 3'd4, S_CHK  = 3'd5;

    reg [2:0]  state;
    reg [7:0]  sum;
    reg [7:0]  cnt;
    reg [19:0] idle_cnt;

    assign in_pop = in_avail;            // always ready to take a byte

    always @(posedge clk) begin
        if (rst) begin
            state <= S_HUNT;
            sum <= 0; cnt <= 0; idle_cnt <= 0;
            buf_we <= 0; buf_addr <= 0; buf_din <= 0;
            done <= 0; ok <= 0; pkt_type <= 0; pkt_seq <= 0; pkt_len <= 0;
            timeout <= 0; bad_len <= 0;
        end else begin
            buf_we  <= 1'b0;
            done    <= 1'b0;
            timeout <= 1'b0;
            bad_len <= 1'b0;

            if (in_avail) begin
                idle_cnt <= 0;
                case (state)
                S_HUNT: if (in_data == SOF) begin
                    sum   <= 8'd0;
                    state <= S_TYPE;
                end
                S_TYPE: begin
                    pkt_type <= in_data;
                    sum      <= sum + in_data;
                    state    <= S_SEQ;
                end
                S_SEQ: begin
                    pkt_seq <= in_data;
                    sum     <= sum + in_data;
                    state   <= S_LEN;
                end
                S_LEN: begin
                    pkt_len <= in_data;
                    sum     <= sum + in_data;
                    cnt     <= 0;
                    if (in_data > MAX_LEN) begin
                        bad_len <= 1'b1;
                        state   <= S_HUNT;
                    end else if (in_data == 0) begin
                        state <= S_CHK;
                    end else begin
                        state <= S_PAY;
                    end
                end
                S_PAY: begin
                    buf_we   <= 1'b1;
                    buf_addr <= cnt[AW-1:0];
                    buf_din  <= in_data;
                    sum      <= sum + in_data;
                    cnt      <= cnt + 8'd1;
                    if (cnt + 8'd1 == pkt_len) state <= S_CHK;
                end
                S_CHK: begin
                    ok    <= ((sum + in_data) == 8'd0);
                    done  <= 1'b1;
                    state <= S_HUNT;
                end
                default: state <= S_HUNT;
                endcase
            end else if (state != S_HUNT) begin
                if (idle_cnt == TIMEOUT - 1) begin
                    idle_cnt <= 0;
                    timeout  <= 1'b1;
                    state    <= S_HUNT;
                end else begin
                    idle_cnt <= idle_cnt + 20'd1;
                end
            end else begin
                idle_cnt <= 0;
            end
        end
    end
endmodule
