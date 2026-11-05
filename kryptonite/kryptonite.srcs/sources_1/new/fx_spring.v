`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// fx_spring.v  (Khushi) - the spring-damper motion curve used by the effects
//
// Every "springy" effect (screen slide, big digit drop-in, particles flying
// into the text) moves like a mass on a spring with some friction:
//
//      a = -k * x  -  c * v          (spring pulls back, damper resists)
//      v = v + a                     (one step per frame, dt = 1)
//      x = x + v
//
// with k = 0.0625 and c = 0.225 (damping ratio 0.45, a little bouncy).
// Starting at x = 1, v = 0, the object rushes towards 0, overshoots by about
// 18%, swings back and settles after ~35 frames (about 0.6 s at 60 fps).
//
// The table was computed once in Python by running exactly those three lines
// 48 times, then scaled by 256 (fixed point, 256 = 1.0). Using a table means
// no multipliers or state per object: any effect just asks "how far along am
// I at frame n?" and scales its own distance by r(n) / 256.
//////////////////////////////////////////////////////////////////////////////
module fx_spring (
    input  wire [5:0]       n,       // frames since the motion started
    output reg  signed [9:0] r       // 256 = still at the start, 0 = arrived
);
    always @(*) begin
        case (n)
            6'd0:  r = 10'sd256;  6'd1:  r = 10'sd240;  6'd2:  r = 10'sd213;
            6'd3:  r = 10'sd178;  6'd4:  r = 10'sd140;  6'd5:  r = 10'sd102;
            6'd6:  r = 10'sd66;   6'd7:  r = 10'sd34;   6'd8:  r = 10'sd7;
            6'd9:  r = -10'sd14;  6'd10: r = -10'sd30;  6'd11: r = -10'sd40;
            6'd12: r = -10'sd45;  6'd13: r = -10'sd47;  6'd14: r = -10'sd45;
            6'd15: r = -10'sd41;  6'd16: r = -10'sd35;  6'd17: r = -10'sd28;
            6'd18: r = -10'sd21;  6'd19: r = -10'sd15;  6'd20: r = -10'sd8;
            6'd21: r = -10'sd3;   6'd22: r = 10'sd1;    6'd23: r = 10'sd4;
            6'd24: r = 10'sd7;    6'd25: r = 10'sd8;    6'd26: r = 10'sd8;
            6'd27: r = 10'sd8;    6'd28: r = 10'sd8;    6'd29: r = 10'sd7;
            6'd30: r = 10'sd6;    6'd31: r = 10'sd4;    6'd32: r = 10'sd3;
            6'd33: r = 10'sd2;    6'd34: r = 10'sd1;
            default: r = 10'sd0;  // settled
        endcase
    end
endmodule
