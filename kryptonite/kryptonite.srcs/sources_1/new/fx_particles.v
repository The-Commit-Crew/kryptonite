`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// fx_particles.v  (Khushi) - particle physics engine for the OLED
//
// Two effects share one frame buffer:
//
// 1. ASSEMBLE: every lit pixel of the message text starts somewhere random
//    on the screen and springs into its place (fx_spring curve), each one
//    leaving at a slightly different time. The text "materialises" out of
//    flying dots, overshoots a little and settles.
//      shown position = home + scatter * r(n) / 256
//    where r(n) is the spring curve and n = frames since that pixel left.
//    Nothing is stored per pixel: the scatter and the delay come from a hash
//    of the pixel's home position, so they are the same every frame.
//    EXPLODE is the same thing run backwards: shown position =
//      home + scatter * (256 - r(n)) / 256
//    so the glyphs (the ciphertext) start in place and burst outwards.
//    Used by the decrypt reveal: ciphertext explodes, plaintext assembles.
//
// 2. FIREWORKS: 64 real particles, each with position and velocity in fixed
//    point (Q8.8: 256 = one pixel). Every frame:
//      vy = vy + g                      gravity pulls down
//      x  = x + vx,   y = y + vy        move
//      at the floor:  vy = -(3/4) vy    bounce, losing 1/4 of the speed
//      at the walls:  vx = -vx          bounce off the sides
//    Four bursts of 16 go off 10 frames apart. Young particles are 2x2 dots,
//    older ones single pixels; colour fades white -> yellow -> orange -> red
//    as each particle's life runs out.
//
// The frame buffer is double buffered (two 96x64 x 4-bit block RAMs): the
// engine draws the next frame into one while the OLED reads the other, then
// they swap on the frame tick, so you never see a half-drawn frame.
// Drawing a frame takes about 12,000 clocks (0.12 ms) out of the 16.7 ms
// available per frame at 60 fps.
//
// Colours are palette indexes (0 = nothing here), turned into RGB565 by
// fx_engine.v: 1 cyan 2 white 3 yellow 4 orange 5 red 6 dark red 7 violet
// 8 green.
//////////////////////////////////////////////////////////////////////////////
module fx_particles (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,          // one pulse per frame (60 Hz)

    // assemble effect: the text being drawn and how far into the effect we are
    input  wire        asm_on,
    input  wire        asm_explode,   // 1: burst outwards (ciphertext), 0: assemble
    input  wire [7:0]  asm_t,         // frames since the effect started
    input  wire [63:0] row1_chars,    // 8 ASCII characters, same layout as
    input  wire [63:0] row2_chars,    // the MSG screen (scale 2, y = 14 and 32)

    // fireworks
    input  wire        fw_start,      // pulse: launch
    output wire        fw_busy,

    // display read port (1 clock latency)
    input  wire [6:0]  rd_x,
    input  wire [5:0]  rd_y,
    output wire [3:0]  rd_color
);
    //================================================================ frame buffer
    (* ram_style = "block" *) reg [3:0] fb0 [0:6143];
    (* ram_style = "block" *) reg [3:0] fb1 [0:6143];
    reg        back;                  // which buffer the engine draws into
    reg        we;
    reg [12:0] waddr;
    reg [3:0]  wdata;
    reg [3:0]  rd0, rd1;

    integer ii;
    initial begin
        for (ii = 0; ii < 6144; ii = ii + 1) begin fb0[ii] = 4'd0; fb1[ii] = 4'd0; end
    end

    wire [12:0] raddr = ({7'd0, rd_y} << 6) + ({7'd0, rd_y} << 5) + {6'd0, rd_x};
    always @(posedge clk) begin
        if (we && !back) fb0[waddr] <= wdata;
        if (we &&  back) fb1[waddr] <= wdata;
        rd0 <= fb0[raddr];
        rd1 <= fb1[raddr];
    end
    assign rd_color = back ? rd0 : rd1;     // show the buffer we're NOT drawing into

    function [12:0] addr_of;
        input [6:0] x;
        input [5:0] y;
        begin
            addr_of = ({7'd0, y} << 6) + ({7'd0, y} << 5) + {6'd0, x};
        end
    endfunction

    //================================================================ random numbers
    // 16-bit Galois LFSR: a new pseudo-random number every clock
    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[0], lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
    end

    // hash of a pixel position: the same input always gives the same output
    function [15:0] hash;
        input [6:0] x;
        input [5:0] y;
        reg [15:0] h;
        begin
            h = {9'd0, x} * 16'd40503 ^ {10'd0, y} * 16'd12345 ^ 16'h5A5A;
            h = h ^ (h >> 7);
            h = h * 16'd9;
            hash = h ^ (h >> 9);
        end
    endfunction

    //================================================================ assemble scanner
    // The scanner walks x = 0..95 across each text row. Instead of dividing x
    // by 12 to find the character (slow), two counters follow along:
    // cc = which character (0..7), cw = pixel inside it (0..11).
    reg  [6:0] sx;
    reg  [5:0] sy;
    reg  [2:0] cc;
    reg  [3:0] cw;
    wire band1 = (sy >= 6'd14) && (sy < 6'd28);
    wire band2 = (sy >= 6'd32) && (sy < 6'd46);
    wire [5:0] sy_in = band1 ? (sy - 6'd14) : (sy - 6'd32);
    wire [63:0] rowc = band1 ? row1_chars : row2_chars;

    // Stage A: look up the character and glyph row (registered)
    reg        a_v;
    reg  [6:0] a_x;
    reg  [5:0] a_y;
    reg  [7:0] a_ch;
    reg  [2:0] a_row, a_col;
    // Stage B: the font says whether this pixel of the glyph is lit
    wire [4:0] a_bits;
    font_rom u_fx_font (.ascii(a_ch), .row(a_row), .bits(a_bits));
    wire a_on = a_v && (a_col < 3'd5) && a_bits[3'd4 - a_col];

    // Stage registers: 1 = text hit, h = hash, 2 = scatter + spring, 3 = position
    reg        s1_v, sh_v, s2_v, s3_v;
    reg  [6:0] s1_x, sh_x, s2_x;
    reg  [5:0] s1_y, sh_y, s2_y;
    reg  [15:0] sh_h;
    reg signed [7:0]  s2_dx, s2_dy;
    reg signed [9:0]  s2_r;
    reg        s2_moving;
    reg signed [9:0]  s3_px, s3_py;
    reg        s3_moving;

    wire [15:0] h1 = sh_h;
    wire [7:0]  delay1 = {4'd0, h1[3:0]};            // leave 0..15 frames late
    wire [7:0]  n1 = (asm_t > delay1) ? (asm_t - delay1) : 8'd0;
    wire [5:0]  n1c = (n1 > 8'd63) ? 6'd63 : n1[5:0];
    wire signed [9:0] r1;
    fx_spring u_spr (.n(n1c), .r(r1));

    // Stage 2 -> 3: position = home + scatter * r / 256
    wire signed [17:0] mx = s2_dx * s2_r;
    wire signed [17:0] my = s2_dy * s2_r;

    //================================================================ fireworks state
    localparam NP = 64;
    reg signed [15:0] px  [0:NP-1];   // Q8.8
    reg signed [15:0] py  [0:NP-1];
    reg signed [11:0] vx  [0:NP-1];
    reg signed [11:0] vy  [0:NP-1];
    reg        [6:0]  life[0:NP-1];
    initial begin
        for (ii = 0; ii < NP; ii = ii + 1) begin
            px[ii] = 0; py[ii] = 0; vx[ii] = 0; vy[ii] = 0; life[ii] = 0;
        end
    end

    localparam signed [11:0] GRAV  = 12'sd20;          // 0.08 pixel / frame^2
    localparam signed [15:0] FLOOR = 16'sd16128;       // y = 63.0
    localparam signed [15:0] RWALL = 16'sd24320;       // x = 95.0

    reg  [5:0] fw_frame;              // frames since launch
    reg        fw_live;
    reg  [5:0] pi;                    // particle being updated
    reg  [2:0] p_half;                // 0 load, 1 compute + write back, 2-4 extra pixels
    reg  [6:0] bx;                    // where this particle was drawn (for 2x2 dots)
    reg  [5:0] by;
    reg  [3:0] bc;
    reg        big;
    reg signed [15:0] cx, cy;
    reg signed [11:0] cvx, cvy;
    reg        [6:0]  cl;
    assign fw_busy = fw_live;

    // which burst (0..3) this particle belongs to, and when/where it fires
    wire [1:0] burst  = pi[5:4];
    wire [5:0] b_time = {burst, 3'b000} + {2'b00, burst, 1'b0};               // 0, 10, 20, 30
    // bursts explode in mid-air: (48,24) (22,18) (74,20) (48,14)
    wire signed [15:0] b_x = (burst == 2'd0) ? 16'sd12288 : (burst == 2'd1) ? 16'sd5632 :
                             (burst == 2'd2) ? 16'sd18944 : 16'sd12288;
    wire signed [15:0] b_y = (burst == 2'd0) ? 16'sd6144  : (burst == 2'd1) ? 16'sd4608 :
                             (burst == 2'd2) ? 16'sd5120  : 16'sd3584;
    // random launch speeds: vx -1.5..+1.5 px/frame, vy -2..+1 px/frame (mostly up)
    wire signed [11:0] rvx = $signed({{2{lfsr[9]}}, lfsr[9:0]});
    wire signed [11:0] rvy = $signed({{2{lfsr[15]}}, lfsr[15:6]});
    wire signed [11:0] launch_vx = (rvx + (rvx >>> 1)) >>> 1;
    wire signed [11:0] launch_vy = ((rvy + (rvy >>> 1)) >>> 1) - 12'sd128;
    wire spawn_now = fw_live && (fw_frame == b_time);

    // physics step for the loaded particle
    wire signed [11:0] nvy0 = cvy + GRAV;
    wire signed [15:0] nx0  = cx + {{4{cvx[11]}}, cvx};
    wire signed [15:0] ny0  = cy + {{4{nvy0[11]}}, nvy0};
    wire hit_floor = (ny0 > FLOOR);
    wire hit_left  = (nx0 < 16'sd0);
    wire hit_right = (nx0 > RWALL);
    wire signed [11:0] bounce_vy = -(nvy0 - (nvy0 >>> 2));        // -(3/4) vy
    wire signed [15:0] nx = hit_left ? 16'sd0 : (hit_right ? RWALL : nx0);
    wire signed [15:0] ny = hit_floor ? FLOOR : ny0;
    wire signed [11:0] nvx = (hit_left || hit_right) ? -cvx : cvx;
    wire signed [11:0] nvy = hit_floor ? bounce_vy : nvy0;

    function [3:0] life_colour;
        input [6:0] l;
        begin
            if      (l > 7'd50) life_colour = 4'd2;   // white
            else if (l > 7'd35) life_colour = 4'd3;   // yellow
            else if (l > 7'd20) life_colour = 4'd4;   // orange
            else if (l > 7'd8)  life_colour = 4'd5;   // red
            else                life_colour = 4'd6;   // dark red
        end
    endfunction

    //================================================================ frame FSM
    localparam F_IDLE = 3'd0, F_CLEAR = 3'd1, F_SCAN = 3'd2, F_FLUSH = 3'd3, F_FW = 3'd4;
    reg [2:0]  fs;
    reg [12:0] caddr;
    reg [2:0]  flush;

    always @(posedge clk) begin
        if (rst) begin
            fs <= F_IDLE; back <= 1'b0; we <= 1'b0; waddr <= 0; wdata <= 0;
            caddr <= 0; sx <= 0; sy <= 6'd14; cc <= 0; cw <= 0; flush <= 0;
            a_v <= 0; a_x <= 0; a_y <= 0; a_ch <= 8'h20; a_row <= 0; a_col <= 0;
            s1_v <= 0; sh_v <= 0; s2_v <= 0; s3_v <= 0;
            s1_x <= 0; s1_y <= 0; sh_x <= 0; sh_y <= 0; sh_h <= 0; s2_x <= 0; s2_y <= 0;
            s2_dx <= 0; s2_dy <= 0; s2_r <= 0; s2_moving <= 0;
            s3_px <= 0; s3_py <= 0; s3_moving <= 0;
            fw_frame <= 0; fw_live <= 1'b0; pi <= 0; p_half <= 0;
            bx <= 0; by <= 0; bc <= 0; big <= 1'b0;
            cx <= 0; cy <= 0; cvx <= 0; cvy <= 0; cl <= 0;
        end else begin
            we <= 1'b0;

            if (fw_start) begin fw_live <= 1'b1; fw_frame <= 6'd0; end

            // ---------------- scan pipeline (runs every clock; only F_SCAN feeds it)
            a_v   <= (fs == F_SCAN) && (band1 || band2);
            a_x   <= sx; a_y <= sy;
            a_ch  <= rowc[(3'd7 - cc) * 8 +: 8];      // first character in the top byte
            a_row <= sy_in[3:1];                      // scale 2: each glyph row is 2 px tall
            a_col <= cw[3:1];                         // and each glyph column 2 px wide

            s1_x <= a_x; s1_y <= a_y;
            s1_v <= a_on;

            sh_v <= s1_v;
            sh_x <= s1_x; sh_y <= s1_y;
            sh_h <= hash(s1_x, s1_y);

            s2_v <= sh_v;
            s2_x <= sh_x; s2_y <= sh_y;
            s2_dx <= $signed(h1[11:4]) >>> 1;            // scatter -64..63 px across
            s2_dy <= $signed({h1[15:12], h1[3:0]}) >>> 2; // and -32..31 px up/down
            s2_r  <= asm_explode ? (10'sd256 - r1) : r1;
            s2_moving <= asm_explode ? (n1 != 8'd0) : (n1 < 8'd30);

            s3_v <= s2_v;
            s3_px <= $signed({3'd0, s2_x}) + (mx >>> 8);
            s3_py <= $signed({4'd0, s2_y}) + (my >>> 8);
            s3_moving <= s2_moving;

            if (s3_v && s3_px >= 0 && s3_px <= 95 && s3_py >= 0 && s3_py <= 63) begin
                we    <= 1'b1;
                waddr <= addr_of(s3_px[6:0], s3_py[5:0]);
                // assemble: cyan/violet in flight, white home
                // explode:   green before it leaves, green/cyan sparks in flight
                wdata <= asm_explode ? (s3_moving ? (lfsr[0] ? 4'd8 : 4'd1) : 4'd8)
                                     : (s3_moving ? (lfsr[0] ? 4'd1 : 4'd7) : 4'd2);
            end

            case (fs)
            F_IDLE: if (tick) begin
                back  <= ~back;               // show what we just drew
                caddr <= 13'd0;
                fs    <= F_CLEAR;
            end

            F_CLEAR: begin                    // wipe the buffer we're about to draw
                we    <= 1'b1;
                waddr <= caddr;
                wdata <= 4'd0;
                if (caddr == 13'd6143) begin
                    sx <= 7'd0; sy <= 6'd14; cc <= 3'd0; cw <= 4'd0;
                    fs <= asm_on ? F_SCAN : F_FW;
                    pi <= 6'd0; p_half <= 3'd0;
                end
                caddr <= caddr + 13'd1;
            end

            F_SCAN: begin                     // visit every pixel of the text rows
                if (sx == 7'd95) begin
                    sx <= 7'd0; cc <= 3'd0; cw <= 4'd0;
                    if (sy == 6'd45) begin fs <= F_FLUSH; flush <= 3'd0; end
                    else sy <= sy + 6'd1;
                end else begin
                    sx <= sx + 7'd1;
                    if (cw == 4'd11) begin cw <= 4'd0; cc <= cc + 3'd1; end
                    else cw <= cw + 4'd1;
                end
            end

            F_FLUSH: begin                    // let the last pixels leave the pipeline
                flush <= flush + 3'd1;
                if (flush == 3'd6) begin fs <= F_FW; pi <= 6'd0; p_half <= 3'd0; end
            end

            F_FW: begin                       // fireworks: up to 5 clocks per particle
                if (!fw_live) begin
                    fs <= F_IDLE;
                end else if (p_half == 3'd0) begin
                    cx <= px[pi]; cy <= py[pi]; cvx <= vx[pi]; cvy <= vy[pi]; cl <= life[pi];
                    p_half <= 3'd1;
                end else if (p_half == 3'd1) begin
                    big <= 1'b0;
                    if (spawn_now) begin
                        // explode: random speed in every direction, mostly upwards
                        px[pi]   <= b_x;
                        py[pi]   <= b_y;
                        vx[pi]   <= launch_vx;
                        vy[pi]   <= launch_vy;
                        life[pi] <= 7'd56 + {2'b00, lfsr[12:8]};
                    end else if (cl != 7'd0) begin
                        px[pi] <= nx; py[pi] <= ny; vx[pi] <= nvx; vy[pi] <= nvy;
                        life[pi] <= cl - 7'd1;
                        if (ny >= 16'sd0) begin       // not drawn while above the top edge
                            we    <= 1'b1;
                            waddr <= addr_of(nx[14:8], ny[13:8]);
                            wdata <= life_colour(cl);
                            bx <= nx[14:8]; by <= ny[13:8]; bc <= life_colour(cl);
                            big <= (cl > 7'd30) && (nx[14:8] < 7'd95) && (ny[13:8] < 6'd63);
                        end
                    end
                    p_half <= 3'd2;
                end else if (p_half != 3'd5 && big) begin
                    // young particles are 2x2 dots: draw the other three pixels
                    we    <= 1'b1;
                    waddr <= (p_half == 3'd2) ? addr_of(bx + 7'd1, by) :
                             (p_half == 3'd3) ? addr_of(bx, by + 6'd1) : addr_of(bx + 7'd1, by + 6'd1);
                    wdata <= bc;
                    p_half <= p_half + 3'd1;
                end else begin
                    p_half <= 3'd0;
                    if (pi == NP - 1) begin
                        fs <= F_IDLE;
                        // one frame of fireworks done; stop after ~2 s
                        if (fw_frame == 6'd63) fw_live <= 1'b0;
                        else                   fw_frame <= fw_frame + 6'd1;
                    end else begin
                        pi <= pi + 6'd1;
                    end
                end
            end
            default: fs <= F_IDLE;
            endcase
        end
    end
endmodule
