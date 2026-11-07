`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// fx_engine.v  (Khushi) - visual effects layered on top of the UI
//
// The UI renderer (ui_screen.v) decides the normal colour of every pixel.
// This module takes that colour and the pixel position and decides whether
// an effect should be drawn there instead. The UI's own files stay untouched.
//
//  Screen  Effect                       How it works
//  ------  ---------------------------  -----------------------------------
//  any     slide-in transition          screen offset follows the spring
//                                       curve (fx_spring): rushes in,
//                                       overshoots, settles
//  DRAW    brush outline                square showing the brush footprint
//  WAIT    orbiting spinner             circle by shifts and adds only:
//                                       x -= y/8, y += x/8 each frame
//  RESULT  "what the model saw"         the 8x8 greyscale grid, 4x4 px cells
//  RESULT  digit drops in               vertical offset follows the spring
//  MSG /   encrypt rain                 pressing send turns the message
//  COMPOSE                              into falling hex for >= 1.5 s (and
//                                       while the link is busy); fireworks
//                                       wait until the rain has cleared
//  RX      decrypt reveal, style 0:     on dec_go (the receiver presses
//  (text)  ciphertext -> particles      decrypt) the real ciphertext bursts
//          -> plaintext                 into particles that fly together into
//                                       the decrypted message, then fireworks
//  RX      decrypt reveal, style 1:     each character flickers through
//  (text)  scramble-then-lock           random hex, then locks left to right
//  RX      sparkle dust                 random sparks whose density halves
//                                       every 10 frames (exponential decay)
//  MSG /   ciphertext view              when show_cipher = 1 the message rows
//  COMPOSE                              show the real ciphertext (first 16
//  / RX                                 hex digits, cipher_hex) in pale green
//  MSG /   fireworks on delivery        gravity + bouncing particles
//  COMPOSE
//  MSG / COMPOSE / RX: small spinner while the link is busy
//
// Screens follow ui_screen: 0 DRAW 1 WAIT 2 RESULT 3 MSG 4 RX 5 COMPOSE.
// Controls (wired in My_Top_Module): effects off = sw[3], style = sw[5],
// replay the decrypt reveal = btnU on the RX screen.
//
// Timing: everything moves on a 60 Hz frame tick made from the 100 MHz clock.
//////////////////////////////////////////////////////////////////////////////
module fx_engine #(
    parameter MAXLEN    = 16,
    parameter FRAME_DIV = 1_666_667        // 100 MHz / 60
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,                 // 0 = plain UI, no effects
    input  wire        style,              // decrypt reveal: 0 scramble, 1 particles

    // pixel being drawn and the UI's colour for it (UI drawn at px_w)
    input  wire [6:0]  px,
    input  wire [5:0]  py,
    output wire [6:0]  px_w,               // shifted x for the slide-in: feed to the UI
    input  wire [15:0] ui_pdata,
    output reg  [15:0] pdata,

    // what the UI is doing
    input  wire [2:0]  state,              // screen shown: 0 DRAW .. 5 COMPOSE
    input  wire [3:0]  digit,
    input  wire [MAXLEN*8-1:0] rx_log,     // received bytes, byte 0 = first character
    input  wire [4:0]  rx_n,
    input  wire        rx_hex,             // RX screen shows hex, not text
    input  wire [319:0] grid,              // 64 cells x 5 bits, 0..16
    input  wire [6:0]  cur_x,
    input  wire [5:0]  cur_y,
    input  wire [1:0]  brush_sel,
    input  wire        link_busy,
    input  wire        link_ok,            // level: last send was delivered
    input  wire        rx_new,             // pulse: a new message arrived
    input  wire        replay,             // pulse: play the decrypt reveal again
    input  wire        enc_go,             // pulse: the user pressed send (encrypt)
    input  wire [63:0] cipher_hex,         // 16 hex digits of real ciphertext, digit 0 in [63:60]
    input  wire        show_cipher,        // level: show cipher_hex in the message rows
    input  wire        dec_go              // pulse: receiver pressed decrypt
);
    localparam S_DRAW = 3'd0, S_WAIT = 3'd1, S_RESULT = 3'd2, S_MSG = 3'd3, S_RX = 3'd4,
               S_COMPOSE = 3'd5;

    localparam BLACK = 16'h0000, WHITE = 16'hFFFF, CYAN = 16'h07FF, YELLOW = 16'hFFE0,
               GREY  = 16'h4208, DCYAN = 16'h0410, ORANGE = 16'hFD20, RED = 16'hF800,
               DRED  = 16'h8000, VIOLET = 16'hB81F, GREEN = 16'h07E0;

    //================================================================ frame tick
    reg [20:0] fdiv;
    reg        tick;
    reg [15:0] fcount;                     // frames since power-up
    always @(posedge clk) begin
        tick <= 1'b0;
        if (rst) begin
            fdiv <= 0; fcount <= 0;
        end else if (fdiv == FRAME_DIV - 1) begin
            fdiv <= 0; tick <= 1'b1; fcount <= fcount + 16'd1;
        end else begin
            fdiv <= fdiv + 21'd1;
        end
    end

    //================================================================ helpers
    function [7:0] dchar;                  // lower case drawn as upper case (same as the UI)
        input [7:0] ch;
        begin
            dchar = (ch >= 8'h61 && ch <= 8'h7A) ? (ch - 8'h20) : ch;
        end
    endfunction
    function [7:0] d2a;                    // digit -> ASCII (same as the UI)
        input [3:0] d;
        begin
            d2a = (d <= 4'd9) ? (8'h30 + {4'd0, d}) : 8'h45;
        end
    endfunction
    function [7:0] h2a;                    // 0..15 -> '0'..'9','A'..'F'
        input [3:0] h;
        begin
            h2a = (h <= 4'd9) ? (8'h30 + {4'd0, h}) : (8'h37 + {4'd0, h});
        end
    endfunction
    function [15:0] mix;                   // cheap hash: same input -> same output
        input [15:0] a;
        input [15:0] b;
        reg [15:0] h;
        begin
            h = a * 16'd40503 ^ b * 16'd12345 ^ 16'h9E37;
            h = h ^ (h >> 7);
            h = h * 16'd9;
            mix = h ^ (h >> 9);
        end
    endfunction

    //================================================================ animation clocks
    reg  [2:0] prev_state;
    reg  [5:0] slide_n;                    // frames into the slide (63 = done)
    reg  [5:0] drop_n;                     // frames into the digit drop
    reg  [7:0] dec_t;                      // frames into the decrypt reveal
    reg        dec_run;
    reg        dec_style;
    reg        fresh;                      // decrypt pressed, reveal not started yet
    reg        dec_fw;                     // fireworks when this reveal finishes
    reg        ok_q;
    reg        fw_go;
    reg        enc_run;                    // encrypt rain running
    reg  [7:0] enc_t;                      // frames into it
    reg        fw_pend;                    // delivered during the rain: fireworks after
    reg [15:0] cseed;                      // picks this reveal's fake ciphertext

    wire slide_on = en && (slide_n < 6'd40);
    wire drop_on  = en && (drop_n  < 6'd40) && (state == S_RESULT);

    wire [4:0] dlen = rx_n;                // the reveal plays on the received message
    wire       rx_text = (state == S_RX) && !rx_hex;
    // style 0 phases (frames): A 0..23 ciphertext shown, B 24..51 it explodes,
    // C 52..131 particles assemble into the plaintext
    localparam [7:0] PH_B = 8'd24, PH_C = 8'd52, DEC0_END = 8'd132;
    wire [7:0] dec_end = dec_style ? (8'd24 + {dlen, 2'b00} + {3'd0, dlen})     // 24 + 5*len
                                   : DEC0_END;
    wire       ph_a = dec_run && !dec_style && (dec_t <  PH_B);
    wire       ph_b = dec_run && !dec_style && (dec_t >= PH_B) && (dec_t < PH_C);
    wire       ph_c = dec_run && !dec_style && (dec_t >= PH_C);
    wire       on_send_screen = (state == S_MSG) || (state == S_COMPOSE);

    always @(posedge clk) begin
        fw_go <= 1'b0;
        if (rst) begin
            prev_state <= S_DRAW; slide_n <= 6'd63; drop_n <= 6'd63;
            dec_t <= 0; dec_run <= 1'b0; dec_style <= 1'b0; fresh <= 1'b0; ok_q <= 1'b0; dec_fw <= 1'b0;
            enc_run <= 1'b0; enc_t <= 8'd0; fw_pend <= 1'b0; cseed <= 16'd0;
        end else begin
            prev_state <= state;
            ok_q <= link_ok;

            // a new screen: start its entrance animation
            if (state != prev_state) begin
                if (state == S_RESULT)                     drop_n  <= 6'd0;
                else if (state != S_WAIT && prev_state != S_WAIT) slide_n <= 6'd0;
                if (state != S_RX) dec_run <= 1'b0;
                enc_run <= 1'b0; fw_pend <= 1'b0;
            end else if (tick) begin
                if (slide_n != 6'd63) slide_n <= slide_n + 6'd1;
                if (drop_n  != 6'd63) drop_n  <= drop_n + 6'd1;
            end

            // decrypt reveal: only when the receiver asks (decrypt) or replays
            if (dec_go) fresh <= 1'b1;
            if (rx_hex && dec_run) dec_run <= 1'b0;        // switched to hex view
            if (!en) fresh <= 1'b0;
            if (en && rx_text && !slide_on && dlen != 5'd0 && (fresh || replay)) begin
                dec_run   <= 1'b1;
                dec_t     <= 8'd0;
                dec_style <= style;
                dec_fw    <= 1'b1;
                fresh     <= 1'b0;
                cseed     <= fcount;
            end else if (dec_run && tick) begin
                if (dec_t >= dec_end) begin
                    dec_run <= 1'b0;
                    if (dec_fw) begin fw_go <= 1'b1; dec_fw <= 1'b0; end   // decrypted: celebrate
                end else dec_t <= dec_t + 8'd1;
            end

            // encrypt rain: starts on send, runs at least 90 frames (1.5 s) and
            // for as long as the link is still busy
            if (en && enc_go && on_send_screen) begin
                enc_run <= 1'b1; enc_t <= 8'd0;
            end else if (enc_run && tick) begin
                if (enc_t != 8'd255) enc_t <= enc_t + 8'd1;
                if (enc_t >= 8'd90 && !link_busy) begin
                    enc_run <= 1'b0;
                    if (fw_pend) begin fw_go <= 1'b1; fw_pend <= 1'b0; end
                end
            end

            // fireworks when our message is delivered (link_ok goes 0 -> 1),
            // held back until the encrypt rain has finished
            if (en && link_ok && !ok_q && on_send_screen) begin
                if (enc_run) fw_pend <= 1'b1;
                else         fw_go   <= 1'b1;
            end
        end
    end

    //================================================================ slide-in warp
    wire signed [9:0]  r_slide;
    fx_spring u_s1 (.n(slide_n), .r(r_slide));
    wire signed [17:0] slide_prod = r_slide * 10'sd96;
    wire signed [9:0]  slide_off  = slide_on ? slide_prod[17:8] : 10'sd0;
    wire signed [9:0]  pxs        = $signed({3'd0, px}) - slide_off;   // content enters from the right
    wire               off_screen = (pxs < 0) || (pxs > 95);
    assign px_w = pxs[6:0];

    //================================================================ particles
    wire [63:0] real_r1, real_r2;
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_rows
            assign real_r1[(7-k)*8 +: 8] = (k < dlen)       ? dchar(rx_log[k*8 +: 8])     : 8'h20;
            assign real_r2[(7-k)*8 +: 8] = ((k + 8) < dlen) ? dchar(rx_log[(k+8)*8 +: 8]) : 8'h20;
        end
    endgenerate

    // the real ciphertext as two rows of 8 hex characters (16 hex digits)
    wire [63:0] cip_r1, cip_r2;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_cip
            assign cip_r1[(7-k)*8 +: 8] = h2a(cipher_hex[(15-k)*4 +: 4]);
            assign cip_r2[(7-k)*8 +: 8] = h2a(cipher_hex[(7-k)*4 +: 4]);
        end
    endgenerate

    wire       asm_on   = ph_b || ph_c;
    wire       asm_expl = ph_b;
    wire [7:0] asm_t    = ph_b ? (dec_t - PH_B) : (dec_t - PH_C);
    wire [63:0] p_r1    = ph_b ? cip_r1 : real_r1;
    wire [63:0] p_r2    = ph_b ? cip_r2 : real_r2;
    wire [3:0] fb_c;
    wire fw_busy;
    fx_particles u_part (
        .clk(clk), .rst(rst), .tick(tick),
        .asm_on(asm_on), .asm_explode(asm_expl), .asm_t(asm_t), .row1_chars(p_r1), .row2_chars(p_r2),
        .fw_start(fw_go), .fw_busy(fw_busy),
        .rd_x(px), .rd_y(py), .rd_color(fb_c));

    reg [15:0] fb_rgb;
    always @(*) begin
        case (fb_c)
            4'd1: fb_rgb = CYAN;   4'd2: fb_rgb = WHITE;  4'd3: fb_rgb = YELLOW;
            4'd4: fb_rgb = ORANGE; 4'd5: fb_rgb = RED;    4'd6: fb_rgb = DRED;
            4'd7: fb_rgb = VIOLET; 4'd8: fb_rgb = GREEN;  default: fb_rgb = BLACK;
        endcase
    end

    //================================================================ scramble-then-lock text
    // character k locks (shows its real value) at frame 8 + 5k; before that it
    // shows a random hex digit that changes every 2 frames
    wire [63:0] scr_r1, scr_r2;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_scr
            wire [15:0] h1 = mix({8'd0, dec_t[7:1]}, k);
            wire [15:0] h2 = mix({8'd0, dec_t[7:1]}, k + 8);
            assign scr_r1[(7-k)*8 +: 8] = (k >= dlen) ? 8'h20 :
                (dec_t >= 8 + 5*k)       ? real_r1[(7-k)*8 +: 8] : h2a(h1[3:0]);
            assign scr_r2[(7-k)*8 +: 8] = ((k + 8) >= dlen) ? 8'h20 :
                (dec_t >= 8 + 5*(k + 8)) ? real_r2[(7-k)*8 +: 8] : h2a(h2[3:0]);
        end
    endgenerate
    wire scr_on1, scr_on2;
    // the same two text lines show the scramble (style 1) or the ciphertext (style 0, phase A)
    wire [63:0] tl_r1 = (dec_run && dec_style) ? scr_r1 : cip_r1;
    wire [63:0] tl_r2 = (dec_run && dec_style) ? scr_r2 : cip_r2;
    text_line #(.N(8), .X0(0), .Y0(14), .SCALE(2)) u_sc1 (.px(px), .py(py), .chars(tl_r1), .on(scr_on1));
    text_line #(.N(8), .X0(0), .Y0(32), .SCALE(2)) u_sc2 (.px(px), .py(py), .chars(tl_r2), .on(scr_on2));

    // which character is this pixel in, and is it locked yet?
    wire [3:0] ck   = px / 12 + ((py >= 6'd32) ? 4'd8 : 4'd0);
    wire [7:0] lock = 8'd8 + {ck, 2'b00} + {4'd0, ck};       // 8 + 5k
    wire locked     = (dec_t >= lock);
    wire just_lock  = locked && (dec_t < lock + 8'd6);       // flash for 6 frames
    wire in_rows    = ((py >= 6'd14) && (py < 6'd28)) || ((py >= 6'd32) && (py < 6'd46));

    //================================================================ sparkle dust
    // density starts at 48/256 of pixels and halves every 10 frames
    wire [7:0]  sp_t     = dec_style ? dec_t : (ph_c ? (dec_t - PH_C) : 8'd200);
    wire [3:0]  halvings = (sp_t > 8'd79) ? 4'd8 : (sp_t / 10);
    wire [7:0]  density  = 8'd48 >> halvings;
    wire [15:0] hs       = mix({px, py, 3'd0}, {8'd0, dec_t[7:1]});
    wire        spark    = dec_run && (dec_style || ph_c) &&
                           (py >= 6'd8) && (py < 6'd52) && (hs[7:0] < density);
    wire [15:0] spark_rgb = hs[9] ? (hs[8] ? WHITE : YELLOW) : CYAN;

    //================================================================ ciphertext rain
    // 16 columns, each with its own speed; the head moves down every frame
    reg  [6:0] head [0:15];
    integer c;
    always @(posedge clk) begin
        if (rst) begin
            for (c = 0; c < 16; c = c + 1) head[c] <= c * 37 % 96;
        end else if (tick) begin
            for (c = 0; c < 16; c = c + 1)
                head[c] <= (head[c] + 1 + (c % 3) >= 96) ? head[c] + 1 + (c % 3) - 96
                                                          : head[c] + 1 + (c % 3);
        end
    end
    wire [3:0]  rc     = px / 6;                         // column
    wire [2:0]  rwx    = px - rc * 6;                    // x inside the 6-px cell
    wire [2:0]  rwy    = py[2:0];                        // y inside the 8-px cell
    wire signed [8:0] rdist = $signed({2'b00, head[rc]}) - $signed({3'b000, py});
    wire        in_tail = (rdist >= 0) && (rdist < 9'sd28);
    wire [15:0] rh      = mix({rc, py[5:3], 9'd0}, fcount[15:3]);
    wire [4:0]  rbits;
    font_rom u_rain_font (.ascii(h2a(rh[3:0])), .row(rwy), .bits(rbits));
    wire        rain_px = in_tail && (rwx < 3'd5) && (rwy < 3'd7) && rbits[4 - rwx];
    wire [15:0] rain_rgb = (rdist < 9'sd3)  ? 16'hAFF5 :     // pale head
                           (rdist < 9'sd10) ? 16'h07E0 :     // bright green
                           (rdist < 9'sd18) ? 16'h0400 :     // mid green
                                              16'h0200;      // faint tail
    wire rain_on = on_send_screen && enc_run && (py >= 6'd9) && (py < 6'd51);   // only while sending

    // ciphertext view: the message rows (and the COMPOSE cursor line under them)
    wire ovl_rows = ((py >= 6'd14) && (py < 6'd30)) || ((py >= 6'd32) && (py < 6'd48));
    wire ovl_on   = show_cipher && !dec_run && !enc_run &&
                    (on_send_screen || ((state == S_RX) && !rx_hex));
    localparam [15:0] PALEGREEN = 16'hAFF5;

    //================================================================ spinner
    // Minsky circle: x -= y/4, then y += x/4 (with the new x). Only shifts and
    // adds, yet the point keeps going round a closed loop (about 25 frames per
    // turn). The trail keeps every 2nd old position so the dots spread out.
    reg signed [15:0] ox, oy;                            // Q8.8, radius 9 px
    reg signed [15:0] tx1, ty1, tx2, ty2, tx3, ty3, hx, hy;
    reg               half;
    always @(posedge clk) begin
        if (rst) begin
            ox <= 16'sd2304; oy <= 16'sd0; half <= 1'b0;
            tx1 <= 0; ty1 <= 0; tx2 <= 0; ty2 <= 0; tx3 <= 0; ty3 <= 0; hx <= 0; hy <= 0;
        end else if (tick) begin : orbit
            reg signed [15:0] nx;
            nx = ox - (oy >>> 2);
            ox <= nx;
            oy <= oy + (nx >>> 2);
            half <= ~half;
            if (half) begin
                tx1 <= ox;  ty1 <= oy;
                tx2 <= tx1; ty2 <= ty1;
                tx3 <= tx2; ty3 <= ty2;
            end
        end
    end
    // centre (48, 50) on WAIT; small one at (88, 12) on MSG while sending
    wire        big_spin = (state == S_WAIT);
    wire signed [9:0] scx = big_spin ? 10'sd48 : 10'sd88;
    wire signed [9:0] scy = big_spin ? 10'sd50 : 10'sd12;
    function near;                                       // 2x2 dot test
        input signed [9:0] x, y, cx, cy;
        input signed [15:0] ox_, oy_;
        input big;
        reg signed [9:0] dx, dy;
        begin
            dx = big ? (ox_ >>> 8) : (ox_ >>> 9);
            dy = big ? (oy_ >>> 8) : (oy_ >>> 9);
            near = (x - (cx + dx) >= 0) && (x - (cx + dx) <= 1) &&
                   (y - (cy + dy) >= 0) && (y - (cy + dy) <= 1);
        end
    endfunction
    wire signed [9:0] sxp = {3'd0, px};
    wire signed [9:0] syp = {4'd0, py};
    wire spin0 = near(sxp, syp, scx, scy, ox,  oy,  big_spin);
    wire spin1 = near(sxp, syp, scx, scy, tx1, ty1, big_spin);
    wire spin2 = near(sxp, syp, scx, scy, tx2, ty2, big_spin);
    wire spin3 = near(sxp, syp, scx, scy, tx3, ty3, big_spin);
    wire spin_on = big_spin ||
                   ((state == S_MSG || state == S_RX || state == S_COMPOSE) && link_busy);

    //================================================================ brush outline
    wire signed [8:0] bdx = $signed({2'b00, px}) - $signed({2'b00, cur_x});
    wire signed [8:0] bdy = $signed({3'b000, py}) - $signed({3'b000, cur_y});
    wire [1:0] brad = (brush_sel == 2'd0) ? 2'd0 : ((brush_sel == 2'd1) ? 2'd1 : 2'd2);
    wire signed [8:0] bo = {7'd0, brad} + 9'sd1;            // outline just outside the brush
    wire brush_ring = (brush_sel != 2'd0) &&
                      ((((bdx == bo) || (bdx == -bo)) && (bdy <= bo) && (bdy >= -bo)) ||
                       (((bdy == bo) || (bdy == -bo)) && (bdx <= bo) && (bdx >= -bo)));

    //================================================================ RESULT: grid preview + digit drop
    wire in_prev  = (px >= 7'd2) && (px < 7'd34) && (py >= 6'd10) && (py < 6'd42);
    wire [6:0] gx = px - 7'd2;
    wire [5:0] gy = py - 6'd10;
    wire [5:0] gcell = {gy[4:2], gx[4:2]};                 // row*8 + col
    wire [4:0] gv = grid[gcell*5 +: 5];
    wire [4:0] grb = (gv == 5'd16) ? 5'd31 : {gv[3:0], 1'b0};
    wire [5:0] gg  = (gv == 5'd16) ? 6'd63 : {gv[3:0], 2'b00};
    wire prev_frame = ((px == 7'd1 || px == 7'd34) && py >= 6'd9 && py <= 6'd42) ||
                      ((py == 6'd9 || py == 6'd42) && px >= 7'd1 && px <= 7'd34);

    wire signed [9:0]  r_drop;
    fx_spring u_s2 (.n(drop_n), .r(r_drop));
    wire signed [17:0] drop_prod = r_drop * 10'sd40;
    wire signed [9:0]  drop_off  = drop_prod[17:8];          // pixels above home
    wire signed [9:0]  pyd       = $signed({4'd0, py}) + drop_off;
    wire               pyd_ok    = (pyd >= 0) && (pyd <= 63);
    wire               big_on;
    text_line #(.N(1), .X0(38), .Y0(10), .SCALE(4)) u_big (.px(px), .py(pyd[5:0]), .chars(d2a(digit)), .on(big_on));
    wire in_big_col = (px >= 7'd38) && (px < 7'd62) && (py < 6'd47);

    //================================================================ layering
    wire [15:0] base = (slide_on && off_screen) ? BLACK : ui_pdata;
    always @(*) begin
        pdata = base;
        // the ciphertext view is information, not decoration: shown even with effects off
        if (ovl_on && ovl_rows) pdata = (scr_on1 || scr_on2) ? PALEGREEN : BLACK;
        if (en) begin
            case (state)
            S_DRAW: begin
                if (base == BLACK && brush_ring) pdata = GREY;
            end
            S_WAIT: begin
                if      (spin0) pdata = WHITE;
                else if (spin1) pdata = CYAN;
                else if (spin2) pdata = DCYAN;
                else if (spin3) pdata = 16'h0208;
            end
            S_RESULT: begin
                if (in_prev)                    pdata = {grb, gg, grb};
                else if (prev_frame)            pdata = DCYAN;
                else if (drop_on && in_big_col) pdata = (big_on && pyd_ok) ? WHITE : BLACK;
            end
            S_MSG, S_COMPOSE: begin
                // encrypting: the message rows dissolve into the hex rain
                if (enc_run && in_rows) pdata = BLACK;
                if (pdata == BLACK && rain_on && rain_px) pdata = rain_rgb;
                if (spin_on) begin
                    if      (spin0) pdata = WHITE;
                    else if (spin1) pdata = CYAN;
                end
                if (fb_c != 4'd0) pdata = fb_rgb;          // fireworks on top
            end
            S_RX: begin
                // decrypt reveal replaces the message rows while it runs
                if (dec_run && in_rows) begin
                    if (dec_style) begin                       // scramble-then-lock
                        if (scr_on1 || scr_on2)
                            pdata = !locked ? GREEN : (just_lock ? YELLOW : WHITE);
                        else pdata = BLACK;
                    end else if (ph_a && (scr_on1 || scr_on2))   // the ciphertext
                        pdata = PALEGREEN;
                    else pdata = BLACK;                        // particles draw B and C
                end
                if (pdata == BLACK && spark) pdata = spark_rgb;
                if (pdata == BLACK && rain_on && rain_px) pdata = rain_rgb;
                if (spin_on) begin
                    if      (spin0) pdata = WHITE;
                    else if (spin1) pdata = CYAN;
                end
                if (fb_c != 4'd0) pdata = fb_rgb;          // particles on top
            end
            default: ;
            endcase
        end
    end
endmodule
