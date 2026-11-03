`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// grid_dump.v  (Khushi)
//
// Sends each new grid to the PC over the Basys3's own USB cable
// (the USB-UART bridge, pin A18), so python/capture_grids.py can save real
// drawings made on the board. Divyansh can add these to the training set,
// which usually helps accuracy a lot, because mouse drawings look different
// from MNIST's pen-on-paper digits.
//
// Format: 0xA5 0x5A, then GBYTES bytes (8 for an 8x8 grid, 32 for 16x16).
// Byte i holds grid bits [8i+7 : 8i]. For 8x8, byte r is row r.
// For 16x16, bytes 2r and 2r+1 are row r.
//////////////////////////////////////////////////////////////////////////////
module grid_dump #(
    parameter GBYTES = 8             // 8 for 8x8, 32 for 16x16
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         tick16,      // shared from uart_link
    input  wire         trigger,     // pulse: send this grid
    input  wire [GBYTES*8-1:0] grid,
    output wire         usb_tx       // to RsTx (A18)
);
    reg  [GBYTES*8-1:0] snap;
    reg  [5:0]   idx;                // 0 .. GBYTES+1
    reg          active, start;
    reg  [7:0]   byte_out;
    wire         ready, done;

    uart_tx u_tx (.clk(clk), .rst(rst), .tick16(tick16), .data(byte_out),
                  .start(start), .tx(usb_tx), .ready(ready), .done(done));

    always @(*) begin
        if (idx == 0)      byte_out = 8'hA5;
        else if (idx == 1) byte_out = 8'h5A;
        else               byte_out = snap[(idx - 2) * 8 +: 8];
    end

    reg waiting;
    always @(posedge clk) begin
        if (rst) begin
            snap <= 0; idx <= 0; active <= 0; start <= 0; waiting <= 0;
        end else begin
            start <= 1'b0;
            if (!active) begin
                if (trigger) begin
                    snap   <= grid;
                    idx    <= 0;
                    active <= 1'b1;
                end
            end else if (!waiting) begin
                if (ready && !start) begin
                    start   <= 1'b1;
                    waiting <= 1'b1;
                end
            end else if (done) begin
                waiting <= 1'b0;
                if (idx == GBYTES + 1) active <= 1'b0;
                else              idx <= idx + 6'd1;
            end
        end
    end
endmodule
