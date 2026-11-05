`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// cipher_rx.v  (Khushi) - Board 2: rebuilds the 768-word ciphertext
//
// Packet format is the one ciphertext_uart_tx sends (crypto/UART.md):
//   12 packets, types 0x10 .. 0x1B = fragment 0 .. 11, each exactly 128 bytes.
//   Each coefficient is 2 bytes, low byte first (upper 4 bits of the high
//   byte are 0), so one packet carries 64 coefficients:
//     fragment f, byte 2k / 2k+1  ->  word f*64 + k
//   Word order: 0..255 u0, 256..511 u1, 512..767 v.
//
// Assembly rules (from UART.md):
//   - a type-0x10 packet of length 128 starts (or restarts) an assembly
//   - fragments must then arrive in order; anything else drops the assembly
//     and we wait for the next 0x10
//   - after fragment 11 (0x1B): ready = 1, new_ct pulses once
// A short type-0x10 packet (1..16 bytes) is a plaintext message and belongs
// to top_fsm's text reader, so length must be exactly 128 here.
// uart_link already drops bad and duplicate packets.
//
// Read port for the decryptor (Divyansh) and ct_check: rd_addr in, rd_data
// one clock later.
//////////////////////////////////////////////////////////////////////////////
module cipher_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,            // pulse: forget the current ciphertext

    // from uart_link (through top_fsm)
    input  wire        lk_rxv,           // pulse: a new packet is in the RX buffer
    input  wire [7:0]  lk_rtype,
    input  wire [7:0]  lk_rlen,
    output reg  [6:0]  lk_ra,            // RX buffer read address
    input  wire [7:0]  lk_rd,            // byte at lk_ra (combinational)

    // result
    output reg  [11:0] got_mask,         // fragments of the current assembly
    output reg         ready,            // all 12 fragments are in
    output reg         new_ct,           // pulse: a complete ciphertext just arrived

    // read port
    input  wire [9:0]  rd_addr,
    output reg  [11:0] rd_data
);
    localparam [7:0] T_FIRST = 8'h10, T_LAST = 8'h1B, FRAG_BYTES = 8'd128;

    reg [11:0] ram [0:767];
    always @(posedge clk) rd_data <= ram[rd_addr];

    reg        we;
    reg [9:0]  wa;
    reg [11:0] wd;
    always @(posedge clk) if (we) ram[wa] <= wd;

    localparam R_IDLE = 2'd0, R_DAT = 2'd1, R_FIN = 2'd2;
    reg [1:0] st;
    reg [3:0] frag;        // fragment being read
    reg [3:0] expect;      // next fragment we will accept
    reg       assembling;
    reg [7:0] lo;          // low byte of the current coefficient

    wire [7:0] t_off   = lk_rtype - T_FIRST;
    wire       is_frag = (lk_rtype >= T_FIRST) && (lk_rtype <= T_LAST) && (lk_rlen == FRAG_BYTES);

    always @(posedge clk) begin
        we <= 1'b0; new_ct <= 1'b0;
        if (rst) begin
            st <= R_IDLE; lk_ra <= 7'd0; got_mask <= 12'd0; ready <= 1'b0;
            frag <= 4'd0; expect <= 4'd0; assembling <= 1'b0; lo <= 8'd0;
            wa <= 10'd0; wd <= 12'd0;
        end else begin
            case (st)
                R_IDLE: if (lk_rxv && is_frag) begin
                    if (t_off == 8'd0) begin                 // start / restart
                        got_mask <= 12'd0; ready <= 1'b0; assembling <= 1'b1;
                        frag <= 4'd0; lk_ra <= 7'd0; st <= R_DAT;
                    end else if (assembling && t_off[3:0] == expect) begin
                        frag <= t_off[3:0]; lk_ra <= 7'd0; st <= R_DAT;
                    end else begin
                        assembling <= 1'b0;                 // out of order: drop it
                        got_mask <= 12'd0;
                    end
                end
                R_DAT: begin                                 // one byte per clock
                    if (!lk_ra[0]) lo <= lk_rd;
                    else begin
                        we <= 1'b1; wa <= {frag, lk_ra[6:1]}; wd <= {lk_rd[3:0], lo};
                    end
                    if (lk_ra == 7'd127) st <= R_FIN;
                    else lk_ra <= lk_ra + 7'd1;
                end
                R_FIN: begin
                    got_mask[frag] <= 1'b1;
                    expect <= frag + 4'd1;
                    if (frag == 4'd11) begin
                        ready <= 1'b1; new_ct <= 1'b1; assembling <= 1'b0;
                    end
                    st <= R_IDLE;
                end
                default: st <= R_IDLE;
            endcase
            if (clear) begin got_mask <= 12'd0; ready <= 1'b0; assembling <= 1'b0; end
        end
    end
endmodule
