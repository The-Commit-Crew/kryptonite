`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ct_check.v  (Khushi) - did the ciphertext arrive exactly right?
//
// After cipher_rx reports a complete ciphertext, this walks all 768 words of
// the received copy and the known copy (ct_source) side by side and counts
// differences. Both memories have a registered read, so the pair for address
// a comes back one clock after a is put out.
//   pass = all 768 words equal, fail = at least one differs.
// Takes 770 clocks (under 8 us).
//////////////////////////////////////////////////////////////////////////////
module ct_check (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,            // pulse: new_ct from cipher_rx
    output reg  [9:0]  addr,             // to both read ports
    input  wire [11:0] got,              // cipher_rx rd_data
    input  wire [11:0] want,             // ct_source data_b
    output reg         running,
    output reg         pass,
    output reg         fail,
    output reg  [9:0]  mismatches        // saturates at 1023
);
    reg cmp;                             // 1: got/want belong to the last address
    always @(posedge clk) begin
        if (rst) begin
            addr <= 10'd0; running <= 1'b0; pass <= 1'b0; fail <= 1'b0;
            mismatches <= 10'd0; cmp <= 1'b0;
        end else begin
            cmp <= running;
            if (start) begin
                addr <= 10'd0; running <= 1'b1; pass <= 1'b0; fail <= 1'b0;
                mismatches <= 10'd0; cmp <= 1'b0;
            end else begin
                if (running) begin
                    if (addr == 10'd767) running <= 1'b0;
                    else addr <= addr + 10'd1;
                end
                if (cmp && got != want && mismatches != 10'h3FF)
                    mismatches <= mismatches + 10'd1;
                if (cmp && !running) begin             // last pair just compared
                    if (mismatches == 10'd0 && got == want) pass <= 1'b1;
                    else                                     fail <= 1'b1;
                end
            end
        end
    end
endmodule
