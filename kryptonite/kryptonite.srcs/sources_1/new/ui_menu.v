`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ui_menu.v  (Khushi) - start-up screens: splash, mode menu, receiver options
//
//   reset -> SPLASH  "KRYPTONITE" with an animated HUD (rotating arcs, orbit,
//                    scan line, bar graph, changing hex). btnR -> MODE
//            MODE    SENDER / RECEIVER.            btnU/btnD move, btnC or btnR pick
//            RXOPT   LISTEN / SELF TEST.           btnL goes back to MODE
//   then the menu is gone (active = 0) until the next reset, and the board runs
//   as:  sender     (draw/type, encrypt, send)
//        listen     (receiver: stays on RX, shows ciphertext, decrypt on btnC)
//        self test  (one board: encrypt your own digits, then decrypt them on RX)
//
// The renderer is combinational in (px, py) like ui_screen, so it plugs into the
// same pixel path. Shapes are drawn with small integer maths:
//   ring of radius r:   |dx^2 + dy^2 - r^2| <= r
//   rotating arc:       on the ring and  dx*cos(a) + dy*sin(a) > threshold
//                       (cos/sin from a 32-step table, 64 = 1.0)
//////////////////////////////////////////////////////////////////////////////
module ui_menu #(
    parameter FRAME_DIV = 1_666_667,       // 60 Hz animation tick at 100 MHz
    parameter SKIP      = 0                // 1: no menu, start as sender (testbenches)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        p_up, p_down, p_left, p_confirm, p_next,   // button pulses
    input  wire [6:0]  px,
    input  wire [5:0]  py,
    output wire        active,             // 1 while a menu screen is shown
    output reg  [15:0] pdata,
    output reg         mode_listen = 1'b0, // receiver, waiting for a sender
    output reg         mode_self   = 1'b0  // receiver, encrypt + decrypt on this board
);
    //------------------------------------------------------------ colours (RGB565)
    localparam [15:0] BG = 16'h0000, GRID = 16'h0103, DIM = 16'h0368, GRN = 16'h2FF1,
                      CY = 16'h069B, WHT = 16'hFFFF, FILL = 16'h0225, PALE = 16'hAFF5;

    //------------------------------------------------------------ menu state
    localparam M_SPLASH = 2'd0, M_MODE = 2'd1, M_RXOPT = 2'd2, M_DONE = 2'd3;
    reg [1:0] ms = SKIP ? M_DONE : M_SPLASH;
    reg       sel = 1'b0;                  // 0 = top option, 1 = bottom option
    assign active = (ms != M_DONE);
    wire pick = p_confirm | p_next;

    always @(posedge clk) begin
        if (rst) begin
            ms <= SKIP ? M_DONE : M_SPLASH; sel <= 1'b0; mode_listen <= 1'b0; mode_self <= 1'b0;
        end else case (ms)
            M_SPLASH: if (p_next || p_confirm) begin ms <= M_MODE; sel <= 1'b0; end
            M_MODE: begin
                if (p_up || p_down) sel <= ~sel;
                else if (pick) begin
                    if (!sel) ms <= M_DONE;                       // SENDER
                    else begin ms <= M_RXOPT; sel <= 1'b0; end    // RECEIVER
                end
            end
            M_RXOPT: begin
                if (p_up || p_down) sel <= ~sel;
                else if (p_left) begin ms <= M_MODE; sel <= 1'b1; end
                else if (pick) begin
                    mode_listen <= ~sel;
                    mode_self   <=  sel;
                    ms <= M_DONE;
                end
            end
            default: ;
        endcase
    end

    //------------------------------------------------------------ animation
    reg [20:0] fdiv = 0;
    reg [7:0]  frame = 0;
    reg [15:0] lfsr = 16'hACE1;
    reg [3:0]  bars [0:5];
    reg [23:0] hexv = 24'hA59F3C;
    integer bi;
    always @(posedge clk) begin
        if (fdiv == FRAME_DIV - 1) begin
            fdiv  <= 0;
            frame <= frame + 8'd1;
            lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (frame[2:0] == 3'd0)
                for (bi = 0; bi < 6; bi = bi + 1)
                    bars[bi] <= 4'd3 + ((lfsr >> (bi * 2)) & 4'd7) + (bi[0] ? 4'd2 : 4'd0);
            if (frame[4:0] == 5'd0) hexv <= {hexv[15:0], lfsr[7:0]};
        end else fdiv <= fdiv + 1;
    end
    initial for (bi = 0; bi < 6; bi = bi + 1) bars[bi] = 4'd6;

    // cos/sin table, 32 steps, 64 = 1.0
    function signed [7:0] cos32;
        input [4:0] a;
        begin
            case (a)
                5'd0: cos32 = 64;   5'd1: cos32 = 63;   5'd2: cos32 = 59;   5'd3: cos32 = 53;
                5'd4: cos32 = 45;   5'd5: cos32 = 36;   5'd6: cos32 = 24;   5'd7: cos32 = 12;
                5'd8: cos32 = 0;    5'd9: cos32 = -12;  5'd10: cos32 = -24; 5'd11: cos32 = -36;
                5'd12: cos32 = -45; 5'd13: cos32 = -53; 5'd14: cos32 = -59; 5'd15: cos32 = -63;
                5'd16: cos32 = -64; 5'd17: cos32 = -63; 5'd18: cos32 = -59; 5'd19: cos32 = -53;
                5'd20: cos32 = -45; 5'd21: cos32 = -36; 5'd22: cos32 = -24; 5'd23: cos32 = -12;
                5'd24: cos32 = 0;   5'd25: cos32 = 12;  5'd26: cos32 = 24;  5'd27: cos32 = 36;
                5'd28: cos32 = 45;  5'd29: cos32 = 53;  5'd30: cos32 = 59;  default: cos32 = 63;
            endcase
        end
    endfunction
    wire [4:0] ang  = frame[6:2];                  // a quarter turn per ~0.5 s
    wire signed [7:0] c1 = cos32(ang),         s1 = cos32(ang - 5'd8);          // rotating
    wire signed [7:0] c2 = cos32(5'd0 - ang),  s2 = cos32(5'd0 - ang - 5'd8);   // counter
    wire signed [7:0] c3 = cos32({ang[3:0], 1'b0}), s3 = cos32({ang[3:0], 1'b0} - 5'd8); // orbit

    //------------------------------------------------------------ geometry
    wire [5:0] cy = (ms == M_SPLASH) ? 6'd33 : 6'd36;
    wire signed [8:0] dx = $signed({2'b00, px}) - 9'sd48;
    wire signed [8:0] dy = $signed({3'b000, py}) - $signed({3'b000, cy});
    wire [8:0] adx = dx[8] ? -dx : dx;
    wire [8:0] ady = dy[8] ? -dy : dy;
    wire [12:0] d2 = adx * adx + ady * ady;
    function ring;                                 // is d2 on the circle of radius r?
        input [12:0] d; input [12:0] r;
        begin ring = (d + r >= r * r) && (d <= r * r + r); end
    endfunction
    wire on22 = ring(d2, 13'd22), on18 = ring(d2, 13'd18), on13 = ring(d2, 13'd13), on9 = ring(d2, 13'd9);
    wire signed [16:0] dot1 = dx * c1 + dy * s1;
    wire signed [16:0] dot2 = dx * c2 + dy * s2;
    wire arc_cy  = on22 && ((dot1 > 17'sd1219) || (dot1 < -17'sd1219));     // two cyan arcs
    wire arc_gn  = on22 && (dot2 > 17'sd1290);                               // green, other way
    wire octant  = dx[8] ^ dy[8] ^ (adx > ady);
    wire dash18  = on18 && octant;
    wire dash9   = on9 && ((dx[1] ^ dy[1]) == 1'b0);
    wire xhair   = ((dx == 0) && (ady <= 3)) || ((dy == 0) && (adx <= 3));
    wire signed [14:0] ox = (18 * c3) >>> 6, oy = (18 * s3) >>> 6;
    wire orbit   = (dx >= ox) && (dx <= ox + 1) && (dy >= oy) && (dy <= oy + 1);
    wire scan    = (py == {1'b0, frame[5:1]} + 6'd12) && (d2 < 13'd484);
    wire grid    = (px[2:0] == 3'd0) && (py[2:0] == 3'd0);
    wire bracket = ((px < 7'd4 || px > 7'd91) && (py == 6'd0 || py == 6'd63)) ||
                   ((py < 6'd4 || py > 6'd59) && (px == 7'd0 || px == 7'd95));
    // bar graph (splash, left side)
    wire [2:0] bar_i = (px - 7'd3) >> 1;
    wire in_bars = (px >= 7'd3) && (px < 7'd15) && !px[0] && (py <= 6'd50) &&
                   (py > 6'd50 - {2'd0, bars[bar_i]});

    //------------------------------------------------------------ text
    function [7:0] h2a; input [3:0] h; begin h2a = (h < 10) ? 8'h30 + h : 8'h37 + h; end endfunction
    reg  [87:0] t_title, t_r1, t_r2;
    reg  [119:0] t_hint;
    always @(*) begin
        case (ms)
            M_SPLASH: begin
                t_title = "KRYPTONITE ";
                t_r1 = "           "; t_r2 = "           ";
                t_hint = frame[5] ? "   PRESS R >   " : "               ";
            end
            M_MODE: begin
                t_title = "SELECT MODE";
                t_r1 = sel ? "  SENDER   " : "> SENDER   ";
                t_r2 = sel ? "> RECEIVER " : "  RECEIVER ";
                t_hint = "  U-D   C:OK   ";
            end
            default: begin
                t_title = " RECEIVER  ";
                t_r1 = sel ? "  LISTEN   " : "> LISTEN   ";
                t_r2 = sel ? "> SELF TEST" : "  SELF TEST";
                t_hint = "U-D C:OK L:BACK";
            end
        endcase
    end
    wire on_title, on_r1, on_r2, on_hint, on_h0, on_h1, on_h2;
    text_line #(.N(11), .X0(15), .Y0(2),  .SCALE(1)) u_t0 (.px(px), .py(py), .chars(t_title), .on(on_title));
    text_line #(.N(11), .X0(15), .Y0(20), .SCALE(1)) u_t1 (.px(px), .py(py), .chars(t_r1),    .on(on_r1));
    text_line #(.N(11), .X0(15), .Y0(38), .SCALE(1)) u_t2 (.px(px), .py(py), .chars(t_r2),    .on(on_r2));
    text_line #(.N(15), .X0(3),  .Y0(55), .SCALE(1)) u_t3 (.px(px), .py(py), .chars(t_hint),  .on(on_hint));
    text_line #(.N(2),  .X0(80), .Y0(18), .SCALE(1)) u_h0 (.px(px), .py(py), .chars({h2a(hexv[23:20]), h2a(hexv[19:16])}), .on(on_h0));
    text_line #(.N(2),  .X0(80), .Y0(27), .SCALE(1)) u_h1 (.px(px), .py(py), .chars({h2a(hexv[15:12]), h2a(hexv[11:8])}),  .on(on_h1));
    text_line #(.N(2),  .X0(80), .Y0(36), .SCALE(1)) u_h2 (.px(px), .py(py), .chars({h2a(hexv[7:4]),   h2a(hexv[3:0])}),    .on(on_h2));
    wire underline = (py == 6'd10) && (px >= 7'd15) && (px < 7'd81);

    // option boxes (menus): top box y 17..30, bottom box y 35..48, x 8..87
    wire in_bx  = (px >= 7'd8) && (px <= 7'd87);
    wire box1   = in_bx && (py >= 6'd17) && (py <= 6'd30);
    wire box2   = in_bx && (py >= 6'd35) && (py <= 6'd48);
    wire edge1  = box1 && (px == 7'd8 || px == 7'd87 || py == 6'd17 || py == 6'd30);
    wire edge2  = box2 && (px == 7'd8 || px == 7'd87 || py == 6'd35 || py == 6'd48);
    wire sel1 = !sel, sel2 = sel;

    //------------------------------------------------------------ layers
    always @(*) begin
        pdata = BG;
        if (grid) pdata = GRID;
        if (ms == M_SPLASH) begin
            if (on13)            pdata = GRID;
            if (dash18)          pdata = DIM;
            if (dash9)           pdata = GRN;
            if (scan)            pdata = FILL;
            if (xhair)           pdata = GRN;
            if (arc_cy)          pdata = CY;
            if (arc_gn)          pdata = GRN;
            if (orbit)           pdata = WHT;
            if (in_bars)         pdata = bar_i[0] ? DIM : GRN;
            if (on_h0 || on_h1 || on_h2) pdata = DIM;
        end else begin
            if (on13)            pdata = GRID;
            if (dash18)          pdata = GRID;
            if (box1 && sel1)    pdata = FILL;
            if (box2 && sel2)    pdata = FILL;
            if (edge1)           pdata = sel1 ? GRN : DIM;
            if (edge2)           pdata = sel2 ? GRN : DIM;
            if (on_r1)           pdata = sel1 ? WHT : DIM;
            if (on_r2)           pdata = sel2 ? WHT : DIM;
        end
        if (on_title)            pdata = GRN;
        if (underline)           pdata = DIM;
        if (on_hint)             pdata = (ms == M_SPLASH) ? GRN : DIM;
        if (bracket)             pdata = CY;
    end
endmodule
