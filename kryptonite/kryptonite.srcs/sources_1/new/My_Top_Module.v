`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: Balakrishnan Shrikkanth
//  STUDENT B NAME: Madnani Khushi
//  STUDENT C NAME: Garg Divyansh
//  STUDENT D NAME: Madhu Kumar Anannya
//////////////////////////////////////////////////////////////////////////////////

// Integration top. Port names match the master .xdc.
//   JA[0] = our TX (JA1), JA[1] = our RX (JA2)
//   sw[15] reset, sw[14] debug, sw[13] board role (0 = MOUSE board, 1 = KEYBOARD board),
//   sw[11:8] debug digit, sw[4] loopback, sw[2] RX screen: 1 = text / 0 = hex, sw[1:0] brush
//   After changing sw[13], press reset (sw[15]).
//   KEYBOARD board: type to compose, Enter = send, Esc = clear, Backspace = delete,
//                   Tab = COMPOSE -> RX text -> RX hex -> COMPOSE, btnD = clear received
module My_Top_Module (
    input  clk,
    input  [15:0] sw,
    input  btnC, btnU, btnL, btnR, btnD,
    output [15:0] led,
    inout  [1:0]  JA,
    output [7:0]  JC,           // Pmod OLED
    inout  PS2Clk,
    inout  PS2Data
);
    localparam MAXLEN = 16;

    //---------------------------------------------------------- reset, role, blink
    reg [1:0] rs = 2'b00;
    always @(posedge clk) rs <= {rs[0], sw[15]};
    wire rst = rs[1];

    reg [1:0] rk = 2'b00;                  // sw[13] through a 2-FF synchroniser
    always @(posedge clk) rk <= {rk[0], sw[13]};
    wire role_kb = rk[1];                  // 1 = keyboard board

    reg [25:0] bcnt = 26'd0;
    always @(posedge clk) bcnt <= bcnt + 26'd1;
    wire blink = bcnt[25];                 // about 3 Hz

    //---------------------------------------------------------- buttons
    wire p_submit, p_confirm, p_retry, p_clear, p_next;
    debounce d_u (.clk(clk), .btn(btnU), .level(), .pulse(p_submit));
    debounce d_c (.clk(clk), .btn(btnC), .level(), .pulse(p_confirm));
    debounce d_l (.clk(clk), .btn(btnL), .level(), .pulse(p_retry));
    debounce d_d (.clk(clk), .btn(btnD), .level(), .pulse(p_clear));
    debounce d_r (.clk(clk), .btn(btnR), .level(), .pulse(p_next));

    //---------------------------------------------------------- mouse (held in reset on the keyboard board)
    wire [11:0] xpos, ypos;
    wire [3:0]  zpos;
    wire        m_left, m_mid, m_right, m_new;
    MouseCtl u_mouse (
        .clk(clk), .rst(rst | role_kb),
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

    //---------------------------------------------------------- keyboard path (only listens on the keyboard board)
    wire [7:0] kb_code;
    wire       kb_valid, kb_err;
    ps2_kbd_rx u_kbrx (
        .clk(clk), .rst(rst | ~role_kb),
        .ps2_clk(PS2Clk), .ps2_data(PS2Data),
        .data(kb_code), .valid(kb_valid), .err(kb_err));

    wire [7:0] kb_key;
    wire       kb_key_v;
    kbd_decode u_kdec (
        .clk(clk), .rst(rst | ~role_kb),
        .code(kb_code), .code_valid(kb_valid),
        .key(kb_key), .key_valid(kb_key_v));

    wire [MAXLEN*8-1:0] ed_msg;
    wire [4:0]          ed_len;
    wire                ed_send;
    msg_edit #(.MAXLEN(MAXLEN)) u_edit (
        .clk(clk), .rst(rst | ~role_kb),
        .key(kb_key), .key_valid(kb_key_v),
        .msg(ed_msg), .len(ed_len), .send(ed_send));

    // keyboard board views: 0 = COMPOSE, 1 = RX text, 2 = RX hex (Tab cycles)
    reg [1:0] kb_view = 2'd0;
    always @(posedge clk) begin
        if (rst | ~role_kb)
            kb_view <= 2'd0;
        else if (kb_key_v && kb_key == 8'h09)
            kb_view <= (kb_view == 2'd2) ? 2'd0 : kb_view + 2'd1;
    end

    //---------------------------------------------------------- UI state machine (mouse board)
    wire [2:0]  state;
    wire [3:0]  digit;
    wire [MAXLEN*4-1:0] msg;
    wire [4:0]  msg_len;
    wire [1:0]  note;
    wire        ctrl_submit, ctrl_clear, ctrl_confirm, ctrl_rxclr;

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
        .submit_out(ctrl_submit), .clear_out(ctrl_clear),
        .confirm_out(ctrl_confirm), .rx_clear_out(ctrl_rxclr));

    wire in_draw = (state == 3'd0);

    //---------------------------------------------------------- the message that is shown and sent
    // mouse board: the confirmed digits become the characters '0'..'9' ('A'..'F' if ever > 9)
    function [7:0] h2a;
        input [3:0] h;
        begin
            h2a = (h <= 4'd9) ? (8'h30 + {4'd0, h}) : (8'h37 + {4'd0, h});
        end
    endfunction

    wire [MAXLEN*8-1:0] dmsg;
    genvar gi;
    generate
        for (gi = 0; gi < MAXLEN; gi = gi + 1) begin : g_conv
            assign dmsg[gi*8 +: 8] = (gi < msg_len) ? h2a(msg[gi*4 +: 4]) : 8'h00;
        end
    endgenerate

    wire [MAXLEN*8-1:0] out_msg = role_kb ? ed_msg : dmsg;
    wire [4:0]          out_len = role_kb ? ed_len : msg_len;

    //---------------------------------------------------------- message layer + UART
    wire [MAXLEN*8-1:0] rx_log;
    wire [4:0]          rx_n;
    wire                link_ok, link_fail, link_busy;
    wire                ja_tx;

    // SEND: keyboard board = Enter, mouse board = btnC on the MESSAGE screen
    wire send_req   = role_kb ? ed_send : (p_confirm & (state == 3'd3));
    // btnD on the RX screen (mouse board) or anywhere on the keyboard board clears the received message
    wire rx_clr_all = ctrl_rxclr | (role_kb & p_clear);

    top_fsm #(.MAXLEN(MAXLEN)) u_fsm (
        .clk(clk), .rst(rst), .loopback(sw[4]),
        .rx_pin(JA[1]), .tx_pin(ja_tx),
        .send_req(send_req), .msg_in(out_msg), .msg_len_in(out_len),
        .rx_clear(rx_clr_all),
        .send_ok(link_ok), .send_fail(link_fail), .tx_busy(link_busy),
        .rx_log(rx_log), .rx_n(rx_n));

    // JA is inout in the master naming: drive pin 0 as TX, pin 1 stays an input
    assign JA[0] = ja_tx;

    //---------------------------------------------------------- vision + ML (Shrikkanth/Khushi)
    wire [12:0] pix;
    wire [6:0]  px;
    wire [5:0]  py;
    wire [6:0] ox;
    wire [5:0] oy;
    assign ox = px;
    assign oy = py;
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
    pix_to_xy u_p2xy (.pix(pix), .x(px), .y(py));

    //---------------------------------------------------------- the renderer
    wire [2:0] scr_state = role_kb ? ((kb_view == 2'd0) ? 3'd5 : 3'd4) : state;
    wire       rx_hex    = role_kb ? (kb_view == 2'd2) : ~sw[2];   // mouse board: sw[2] up = text

    wire [15:0] pdata;
    ui_screen #(.MAXLEN(MAXLEN)) u_screen (
        .px(px), .py(py), .state(scr_state), .digit(digit),
        .msg(out_msg), .msg_len(out_len),
        .rx_log(rx_log), .rx_n(rx_n), .rx_hex(rx_hex),
        .role_kb(role_kb), .blink(blink), .note(note),
        .link_ok(link_ok), .link_fail(link_fail),
        .cur_x(cur_x), .cur_y(cur_y),
        .oink(oink), .has_ink(has_ink),
        .bxmin(bxmin), .bxmax(bxmax), .bymin(bymin), .bymax(bymax),
        .pdata(pdata));

    Oled_Display u_oled (
        .clk(clk6p25), .reset(rst),
        .frame_begin(), .sending_pixels(), .sample_pixel(),
        .pixel_index(pix), .pixel_data(pdata),
        .cs(JC[0]), .sdin(JC[1]), .sclk(JC[3]), .d_cn(JC[4]),
        .resn(JC[5]), .vccen(JC[6]), .pmoden(JC[7]));
    assign JC[2] = 1'b0;

    //---------------------------------------------------------- LEDs
    // [15:11] message length  [10] note  [9] left click  [8:5] digit  [4] busy  [3] has_ink  [2:0] state
    assign led = {out_len, (note != 2'd0), m_left, digit, busy_i, has_ink, state};
endmodule