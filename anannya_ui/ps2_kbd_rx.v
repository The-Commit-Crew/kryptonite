`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ps2_kbd_rx.v (Anannya) - receive-only PS/2 reader
//  * only LISTENS to ps2_clk / ps2_data, never drives them
//  * frame = start(0), 8 data bits LSB first, odd parity, stop(1)
//  * valid = 1-clock pulse with a good byte; err = 1-clock pulse on a bad frame
//  * a frame that stalls for TMO clocks is dropped (re-sync)
//////////////////////////////////////////////////////////////////////////////
module ps2_kbd_rx #(
    parameter [31:0] TMO = 32'd50_000           // 500 us at 100 MHz
)(
    input  clk,
    input  rst,
    input  ps2_clk,
    input  ps2_data,
    output reg [7:0] data  = 8'd0,
    output reg       valid = 1'b0,
    output reg       err   = 1'b0
);
    reg [2:0]  cs   = 3'b111;                   // synchroniser chains
    reg [2:0]  ds   = 3'b111;
    reg [10:0] fr   = 11'd0;
    reg [3:0]  cnt  = 4'd0;                     // bits received so far
    reg [31:0] idle = 32'd0;

    always @(posedge clk) begin
        cs <= {cs[1:0], ps2_clk};
        ds <= {ds[1:0], ps2_data};
    end

    // falling edge of the device clock; ds[1] is the data bit at that moment
    wire        fall = cs[2] & ~cs[1];
    wire [10:0] nf   = {ds[1], fr[10:1]};       // frame including this new bit
    // start must be 0, stop must be 1, data+parity must hold an odd number of 1s
    wire        good = ~nf[0] & nf[10] & (^nf[9:1]);

    always @(posedge clk) begin
        valid <= 1'b0;
        err   <= 1'b0;
        if (rst) begin
            cnt <= 4'd0; idle <= 32'd0; fr <= 11'd0;
        end else if (fall) begin
            idle <= 32'd0;
            fr   <= nf;
            if (cnt == 4'd10) begin             // that was the 11th bit
                cnt <= 4'd0;
                if (good) begin data <= nf[8:1]; valid <= 1'b1; end
                else      err <= 1'b1;
            end else
                cnt <= cnt + 4'd1;
        end else if (cnt != 4'd0) begin
            idle <= idle + 32'd1;
            if (idle == TMO) begin cnt <= 4'd0; idle <= 32'd0; end   // stalled: drop it
        end
    end
endmodule