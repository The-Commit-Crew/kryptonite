`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ct_source.v  (Khushi) - a known ciphertext for testing the link
//
// Holds Shrikkanth's test vector (crypto/test_vectors/ciphertext: the
// message "Kryptonite FPGA encryption demo!" encrypted with the board 1
// keys). Word order matches board1_send: 0..255 u0, 256..511 u1, 512..767 v.
//
// Used two ways in the ciphertext test mode (cipher_link):
//   sender:   ciphertext_uart_tx reads the words to send from here
//   receiver: ct_check compares what arrived against the same words
// Real encrypted sends come from board1_send through top_fsm instead.
//
// Vivado: add u0.mem, u1.mem and v.mem (crypto/test_vectors/ciphertext/) to
// the project as design sources, so these plain file names are found.
//////////////////////////////////////////////////////////////////////////////
module ct_source #(
    parameter U0_FILE = "u0.mem",
    parameter U1_FILE = "u1.mem",
    parameter V_FILE  = "v.mem"
)(
    input  wire        clk,
    input  wire [9:0]  addr_a,           // port A (ciphertext_uart_tx)
    output reg  [11:0] data_a,
    input  wire [9:0]  addr_b,           // port B (ct_check)
    output reg  [11:0] data_b
);
    reg [11:0] rom [0:767];
    initial begin
        $readmemh(U0_FILE, rom,   0, 255);
        $readmemh(U1_FILE, rom, 256, 511);
        $readmemh(V_FILE,  rom, 512, 767);
    end
    always @(posedge clk) begin
        data_a <= rom[addr_a];
        data_b <= rom[addr_b];
    end
endmodule
