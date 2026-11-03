`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// pkt_tx.v  (Khushi)
//
// Wraps a message into a packet and sends it byte by byte through uart_tx.
//
//   byte:   0      1      2      3      4 .. 3+LEN       last
//         [0x7E] [TYPE] [SEQ]  [LEN]  [payload ...]     [CHK]
//
//   0x7E   start-of-frame marker, so the receiver knows where a packet begins
//   TYPE   0x02 = ACK, 0x03 = NAK, 0x10 and above = data (e.g. 0x10 ciphertext)
//   SEQ    sequence number, goes up by 1 for every new data packet
//   LEN    number of payload bytes (0 for ACK / NAK)
//   CHK    checksum, chosen so that  TYPE + SEQ + LEN + payload + CHK = 0
//          (mod 256). So CHK = 0 - (sum of the others), which is the
//          two's-complement negation of the sum. The receiver just adds
//          every byte it gets and checks the total is 0.
//
// 'corrupt' (fault injection for the demo) flips one bit of CHK, so this
// packet is guaranteed to fail the receiver's checksum.
//////////////////////////////////////////////////////////////////////////////
module pkt_tx #(
    parameter AW = 7                    // payload buffer address width
)(
    input  wire          clk,
    input  wire          rst,

    input  wire          start,         // pulse: send a packet
    input  wire [7:0]    type_in,
    input  wire [7:0]    seq_in,
    input  wire [7:0]    len_in,
    input  wire          corrupt,

    // payload buffer read port (combinational read)
    output wire [AW-1:0] rd_addr,
    input  wire [7:0]    rd_data,

    // to uart_tx
    output reg  [7:0]    tx_data,
    output reg           tx_start,
    input  wire          tx_ready,
    input  wire          tx_done,

    output wire          busy,
    output reg           done           // pulse when the whole packet is out
);
    localparam SOF = 8'h7E;
    localparam S_IDLE = 2'd0, S_LOAD = 2'd1, S_WAIT = 2'd2;

    reg [1:0] state;
    reg [8:0] idx;                      // byte position in the packet
    reg [7:0] typ, seq, len;
    reg       bad;
    reg [7:0] sum;

    assign busy    = (state != S_IDLE);
    assign rd_addr = idx[AW-1:0] - 4;   // payload byte (idx - 4)

    wire [8:0] last_idx = {1'b0, len} + 9'd4;   // index of CHK

    // byte to send at position idx
    reg [7:0] cur;
    always @(*) begin
        if      (idx == 0)        cur = SOF;
        else if (idx == 1)        cur = typ;
        else if (idx == 2)        cur = seq;
        else if (idx == 3)        cur = len;
        else if (idx < last_idx)  cur = rd_data;
        else                      cur = (8'd0 - sum) ^ {7'd0, bad};
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            idx <= 0; typ <= 0; seq <= 0; len <= 0; bad <= 0; sum <= 0;
            tx_data <= 0; tx_start <= 1'b0; done <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            done <= 1'b0;
            case (state)
            S_IDLE: if (start) begin
                typ <= type_in; seq <= seq_in; len <= len_in;
                bad <= corrupt;
                sum <= 8'd0;
                idx <= 0;
                state <= S_LOAD;
            end
            S_LOAD: if (tx_ready && !tx_start) begin
                tx_data  <= cur;
                tx_start <= 1'b1;
                if (idx != 0 && idx < last_idx)
                    sum <= sum + cur;          // running checksum
                state <= S_WAIT;
            end
            S_WAIT: if (tx_done) begin
                if (idx == last_idx) begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    idx   <= idx + 9'd1;
                    state <= S_LOAD;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
