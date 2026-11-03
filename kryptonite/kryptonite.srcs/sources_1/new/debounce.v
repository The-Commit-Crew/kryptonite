`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// debounce.v  (Khushi)
//
// A pushbutton "bounces": for a few milliseconds after pressing, the contact
// flickers between 0 and 1. Without this, one press could count as several.
// We sample the button every ~1.3 ms and only accept a new level once it has
// been the same for 4 samples in a row. 'pulse' is high for one clock when
// the clean signal goes from 0 to 1 (one pulse per press).
//////////////////////////////////////////////////////////////////////////////
module debounce (
    input  wire clk,
    input  wire btn,
    output reg  level,
    output reg  pulse
);
    reg [16:0] div = 0;
    reg [3:0]  hist = 0;
    reg        s1 = 0, s2 = 0;
    initial begin level = 0; pulse = 0; end

    always @(posedge clk) begin
        s1 <= btn; s2 <= s1;               // synchronise
        div <= div + 17'd1;
        pulse <= 1'b0;
        if (div == 0) begin
            hist <= {hist[2:0], s2};
            if ({hist[2:0], s2} == 4'b1111 && !level) begin
                level <= 1'b1;
                pulse <= 1'b1;
            end else if ({hist[2:0], s2} == 4'b0000) begin
                level <= 1'b0;
            end
        end
    end
endmodule
