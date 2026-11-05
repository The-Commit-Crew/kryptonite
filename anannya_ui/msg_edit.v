`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// msg_edit.v (Anannya) - typing buffer, one byte per character
//  printable key -> append (ignored when full)   Backspace -> delete last
//  Esc -> clear all                              Enter -> send pulse (if not empty)
//  The text stays after Enter. Esc clears it.
//////////////////////////////////////////////////////////////////////////////
module msg_edit #(
    parameter MAXLEN = 16
)(
    input  clk,
    input  rst,
    input  [7:0] key,
    input  key_valid,
    output reg [MAXLEN*8-1:0] msg  = 0,       // byte 0 = first character
    output reg [4:0]          len  = 5'd0,
    output reg                send = 1'b0     // one-clock pulse
);
    always @(posedge clk) begin
        send <= 1'b0;
        if (rst) begin
            msg <= 0; len <= 5'd0;
        end else if (key_valid) begin
            if (key >= 8'h20 && key <= 8'h7E) begin
                if (len < MAXLEN) begin
                    msg[len*8 +: 8] <= key;
                    len <= len + 5'd1;
                end
            end else if (key == 8'h08) begin
                if (len != 5'd0) begin
                    msg[(len-1)*8 +: 8] <= 8'h00;
                    len <= len - 5'd1;
                end
            end else if (key == 8'h1B) begin
                msg <= 0; len <= 5'd0;
            end else if (key == 8'h0D) begin
                if (len != 5'd0) send <= 1'b1;
            end
        end
    end
endmodule