`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// baud_gen.v  (Khushi)
//
// Makes a one-clock 'tick16' pulse at 16 x the baud rate (16 x 115200 =
// 1,843,200 ticks per second). The UART samples and sends using these ticks.
//
// Why not just divide 100 MHz by an integer?  100e6 / 1,843,200 = 54.25,
// which is not a whole number. Dividing by 54 gives a 0.47% error.
//
// Instead we use a phase accumulator (fractional divider): every clock add
// INC to a 16-bit counter; whenever it overflows, that's a tick.
//      tick rate = 100 MHz * INC / 65536
//      INC = 1,843,200 * 65536 / 100e6 = 1207.96  ->  1208
//      actual = 100e6 * 1208 / 65536 = 1,843,262 Hz  ->  error 0.003%
// The ticks are not perfectly evenly spaced (54 or 55 clocks apart), but on
// average they are exact, which is what matters over a 10-bit frame.
//
// For other baud rates: INC = round(BAUD * 16 * 65536 / CLK_HZ).
//////////////////////////////////////////////////////////////////////////////
module baud_gen #(
    parameter [15:0] INC = 16'd1208      // 115200 baud at 100 MHz
)(
    input  wire clk,
    input  wire rst,
    output reg  tick16
);
    reg [15:0] acc;
    always @(posedge clk) begin
        if (rst) begin
            acc    <= 16'd0;
            tick16 <= 1'b0;
        end else begin
            {tick16, acc} <= {1'b0, acc} + {1'b0, INC};
        end
    end
endmodule
