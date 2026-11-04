`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 06:20:57 PM
// Design Name: 
// Module Name: ui_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ui_top(
    input clk,
    input [15:0] sw,
    input btnC, btnU, btnD, btnL, btnR,
    output [15:0] led,
    output [7:0]  JC,
    inout  PS2Clk,
    inout  PS2Data
);
    localparam MAXLEN = 16;
    localparam S_DRAW = 2'd0, S_WAIT = 2'd1, S_RESULT = 2'd2, S_MSG = 2'd3;
    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, CYAN = 16'h07FF, YELLOW = 16'hFFE0;

    //---------------------------------------------------------- reset: sw[15]
    reg [1:0] rs = 2'b00;
    always @(posedge clk) rs <= {rs[0], sw[15]};
    wire rst = rs[1];

    //---------------------------------------------------------- buttons
    wire p_submit, p_confirm, p_retry, p_clear, p_next;
    debounce d_u (.clk(clk), .btn(btnU), .level(), .pulse(p_submit));
    debounce d_c (.clk(clk), .btn(btnC), .level(), .pulse(p_confirm));
    debounce d_l (.clk(clk), .btn(btnL), .level(), .pulse(p_retry));
    debounce d_d (.clk(clk), .btn(btnD), .level(), .pulse(p_clear));
    debounce d_r (.clk(clk), .btn(btnR), .level(), .pulse(p_next));

    //---------------------------------------------------------- mouse (from top_khushi)
    wire [11:0] xpos, ypos;
    wire [3:0]  zpos;
    wire        m_left, m_mid, m_right, m_new;
    MouseCtl u_mouse (
        .clk(clk), .rst(rst),
        .xpos(xpos), .ypos(ypos), .zpos(zpos),
        .left(m_left), .middle(m_mid), .right(m_right), .new_event(m_new),
        .value(12'd0), .setx(1'b0), .sety(1'b0), .setmax_x(1'b0), .setmax_y(1'b0),
        .ps2_clk(PS2Clk), .ps2_data(PS2Data));

    // divide by 10: n/10 = (n*3277) >> 15 (Khushi's trick), then clamp to the screen
    wire [23:0] xm = xpos * 12'd3277;
    wire [23:0] ym = ypos * 12'd3277;
    wire [11:0] xd = xm[23:15];
    wire [11:0] yd = ym[23:15];
    wire [6:0]  cur_x = (xd > 95) ? 7'd95 : xd[6:0];
    wire [5:0]  cur_y = (yd > 63) ? 6'd63 : yd[5:0];

    reg mid_q = 1'b0;
    always @(posedge clk) mid_q <= m_mid;
    wire mid_pulse = m_mid & ~mid_q;

    //---------------------------------------------------------- UI state machine
    wire [1:0]  state;
    wire [3:0]  digit;
    wire [MAXLEN*4-1:0] msg;
    wire [4:0]  msg_len;
    wire [1:0]  note;
    wire        ctrl_submit, ctrl_clear;

    wire        v_busy, has_ink, oink;
    wire        grid_valid, grid_empty, prediction_valid;
    wire [3:0]  prediction;
    wire [6:0]  bxmin, bxmax;
    wire [5:0]  bymin, bymax;
    wire [319:0] grid;

    // ---- debug mode: sw[14] fakes a prediction (digit = sw[11:8]) ----
    wire       dbg_en    = sw[14];
    wire [3:0] dbg_digit = sw[11:8];
    reg [19:0] fcnt = 20'd0;
    reg        frun = 1'b0, fake_valid = 1'b0;
    always @(posedge clk) begin
        fake_valid <= 1'b0;
        if (rst) begin
            frun <= 1'b0; fcnt <= 20'd0;
        end else if (!frun) begin
            if (ctrl_submit && dbg_en) begin frun <= 1'b1; fcnt <= 20'd0; end
        end else begin
            fcnt <= fcnt + 20'd1;
            if (&fcnt) begin frun <= 1'b0; fake_valid <= 1'b1; end
        end
    end

    wire       pred_valid_i = dbg_en ? fake_valid : prediction_valid;
    wire [3:0] pred_i       = dbg_en ? dbg_digit  : prediction;
    wire       empty_i      = dbg_en ? 1'b0       : (grid_valid & grid_empty);
    wire       busy_i       = dbg_en ? 1'b0       : v_busy;

    ui_ctrl #(.MAXLEN(MAXLEN)) u_ctrl (
        .clk(clk), .rst(rst),
        .p_submit(p_submit), .p_confirm(p_confirm), .p_retry(p_retry),
        .p_clear(p_clear), .p_next(p_next),
        .busy_i(busy_i), .pred_valid(pred_valid_i), .pred(pred_i), .empty_i(empty_i),
        .state(state), .digit(digit), .msg(msg), .msg_len(msg_len), .note(note),
        .submit_out(ctrl_submit), .clear_out(ctrl_clear));

    wire in_draw = (state == S_DRAW);
    wire msg_full = (msg_len >= MAXLEN);

    //---------------------------------------------------------- vision + ML (Shrikkanth/Khushi)
    wire [6:0] ox;
    wire [5:0] oy;
    vision_ml u_vml (
        .clk(clk), .rst(rst),
        .cursor_x(cur_x), .cursor_y(cur_y),
        .paint(m_left & in_draw),
        .erase(m_right & ~m_left & in_draw),
        .clear(ctrl_clear | (mid_pulse & in_draw)),
        .brush_sel(sw[1:0]),
        .submit(ctrl_submit),
        .oled_x(ox), .oled_y(oy), .oled_ink(oink),
        .has_ink(has_ink),
        .box_xmin(bxmin), .box_xmax(bxmax), .box_ymin(bymin), .box_ymax(bymax),
        .grid(grid), .grid_valid(grid_valid), .grid_empty(grid_empty),
        .busy(v_busy),
        .prediction(prediction), .prediction_valid(prediction_valid));

    //---------------------------------------------------------- OLED clock + pixel position
    reg [2:0] cdiv = 3'd0;
    reg       clk6p25 = 1'b0;
    always @(posedge clk) begin
        cdiv <= cdiv + 3'd1;
        if (cdiv == 3'd7) clk6p25 <= ~clk6p25;      // 100 MHz / 16 = 6.25 MHz
    end

    wire [12:0] pix;
    wire [6:0]  px;
    wire [5:0]  py;
    pix_to_xy u_p2xy (.pix(pix), .x(px), .y(py));
    assign ox = px;
    assign oy = py;

    //---------------------------------------------------------- shapes on the DRAW screen
    wire signed [8:0] ddx = $signed({2'b00, px}) - $signed({2'b00, cur_x});
    wire signed [8:0] ddy = $signed({3'b000, py}) - $signed({3'b000, cur_y});
    wire on_cursor = ((ddx == 0) && (ddy >= -1) && (ddy <= 1)) ||
                     ((ddy == 0) && (ddx >= -1) && (ddx <= 1));
    wire on_box = has_ink &&
                  ( ((px == bxmin || px == bxmax) && py >= bymin && py <= bymax) ||
                    ((py == bymin || py == bymax) && px >= bxmin && px <= bxmax) );

    //---------------------------------------------------------- text
    function [7:0] d2a;
        input [3:0] d;
        begin
            d2a = (d <= 4'd9) ? (8'h30 + {4'd0, d}) : 8'h45;   // digit, else 'E'
        end
    endfunction

    // note on the DRAW screen
    wire [39:0] note_chars = (note == 2'd1) ? "EMPTY" : "ERR  ";
    wire t_note;
    text_line #(.N(5), .X0(0), .Y0(0), .SCALE(1)) u_t_note (.px(px), .py(py), .chars(note_chars), .on(t_note));

    // WAIT screen
    wire t_wait;
    text_line #(.N(4), .X0(24), .Y0(25), .SCALE(2)) u_t_wait (.px(px), .py(py), .chars("WAIT"), .on(t_wait));

    // RESULT screen: big digit plus a hint line
    wire [7:0] big_char = d2a(digit);
    wire t_big, t_hint;
    text_line #(.N(1), .X0(38), .Y0(10), .SCALE(4)) u_t_big (.px(px), .py(py), .chars(big_char), .on(t_big));
    wire [95:0] hint_chars = msg_full ? "FULL L:RETRY" : "C:OK L:RETRY";
    text_line #(.N(12), .X0(12), .Y0(48), .SCALE(1)) u_t_hint (.px(px), .py(py), .chars(hint_chars), .on(t_hint));

    // MESSAGE screen: header with the length, two rows of 8 digits, a hint line
    wire [7:0] len_t = (msg_len >= 5'd10) ? 8'h31 : 8'h30;
    wire [4:0] len_u5 = (msg_len >= 5'd10) ? (msg_len - 5'd10) : msg_len;
    wire [7:0] len_u = 8'h30 + {4'd0, len_u5[3:0]};
    wire [47:0] hdr_chars = {"MSG ", len_t, len_u};
    wire t_hdr, t_row1, t_row2, t_mhint;
    text_line #(.N(6), .X0(0), .Y0(0), .SCALE(1)) u_t_hdr (.px(px), .py(py), .chars(hdr_chars), .on(t_hdr));

    wire [63:0] row1_chars, row2_chars;
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_row
            assign row1_chars[(7-k)*8 +: 8] = (k < msg_len)     ? d2a(msg[k*4 +: 4])     : 8'h20;
            assign row2_chars[(7-k)*8 +: 8] = ((k + 8) < msg_len) ? d2a(msg[(k+8)*4 +: 4]) : 8'h20;
        end
    endgenerate
    text_line #(.N(8), .X0(0), .Y0(14), .SCALE(2)) u_t_r1 (.px(px), .py(py), .chars(row1_chars), .on(t_row1));
    text_line #(.N(8), .X0(0), .Y0(32), .SCALE(2)) u_t_r2 (.px(px), .py(py), .chars(row2_chars), .on(t_row2));
    text_line #(.N(12), .X0(12), .Y0(54), .SCALE(1)) u_t_mh (.px(px), .py(py), .chars("D:CLR R:BACK"), .on(t_mhint));

    //---------------------------------------------------------- colour for this pixel
    // priority mux: the first match wins
    reg [15:0] pdata;
    always @* begin
        pdata = BLACK;
        case (state)
            S_DRAW: begin
                if      (on_cursor)               pdata = RED;
                else if (note != 2'd0 && t_note)  pdata = YELLOW;
                else if (oink)                    pdata = WHITE;
                else if (on_box)                  pdata = GREEN;
            end
            S_WAIT: begin
                if (t_wait) pdata = CYAN;
            end
            S_RESULT: begin
                if      (t_big)  pdata = WHITE;
                else if (t_hint) pdata = msg_full ? RED : GREEN;
            end
            S_MSG: begin
                if      (t_hdr)            pdata = YELLOW;
                else if (t_row1 | t_row2)  pdata = WHITE;
                else if (t_mhint)          pdata = GREEN;
            end
        endcase
    end

    Oled_Display u_oled (
        .clk(clk6p25), .reset(rst),
        .frame_begin(), .sending_pixels(), .sample_pixel(),
        .pixel_index(pix), .pixel_data(pdata),
        .cs(JC[0]), .sdin(JC[1]), .sclk(JC[3]), .d_cn(JC[4]),
        .resn(JC[5]), .vccen(JC[6]), .pmoden(JC[7]));
    assign JC[2] = 1'b0;

    //---------------------------------------------------------- LEDs
    assign led = {msg_len, (note != 2'd0), dbg_en, m_left, digit, busy_i, has_ink, state};
endmodule