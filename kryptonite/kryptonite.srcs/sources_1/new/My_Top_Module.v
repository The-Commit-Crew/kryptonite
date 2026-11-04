`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
//  FILL IN THE FOLLOWING INFORMATION:
//  STUDENT A NAME: 
//  STUDENT B NAME:
//  STUDENT C NAME: 
//  STUDENT D NAME:
//////////////////////////////////////////////////////////////////////////////////

// Integration top. Port names match the master .xdc.
//   JA[0] = our TX (JA1), JA[1] = our RX (JA2)
//   sw[15] reset, sw[14] debug, sw[13] role (0 sender / 1 receiver), sw[11:8] debug digit,
//   sw[4] loopback, sw[1:0] brush
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

    //---------------------------------------------------------- reset: sw[15], role: sw[13]
    reg [1:0] rs = 2'b00;
    always @(posedge clk) rs <= {rs[0], sw[15]};
    wire rst = rs[1];
    wire role_rx = sw[13];                 // 0 = sender, 1 = receiver (read live)

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

    //---------------------------------------------------------- message layer + UART
    wire [MAXLEN*8-1:0] rx_log;
    wire [4:0]          rx_n;
    wire [MAXLEN*4-1:0] rmsg;
    wire [4:0]          rmsg_len;
    wire                link_ok, link_fail, link_busy;
    wire                ja_tx;

    // SEND = btnC while on the MESSAGE screen (sender role only)
    wire send_req   = p_confirm & (state == 3'd3) & ~role_rx;
    // receiver role: btnD on the MESSAGE screen clears the received message
    wire rx_clr_all = ctrl_rxclr | (p_clear & (state == 3'd3) & role_rx);

    top_fsm #(.MAXLEN(MAXLEN)) u_fsm (
        .clk(clk), .rst(rst), .loopback(sw[4]),
        .rx_pin(JA[1]), .tx_pin(ja_tx),
        .send_req(send_req), .msg_in(msg), .msg_len_in(msg_len),
        .rx_clear(rx_clr_all),
        .send_ok(link_ok), .send_fail(link_fail), .tx_busy(link_busy),
        .rx_log(rx_log), .rx_n(rx_n), .rmsg(rmsg), .rmsg_len(rmsg_len));

    // JA is inout in the master naming: drive pin 0 as TX, pin 1 stays an input
    assign JA[0] = ja_tx;

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

    //---------------------------------------------------------- the renderer
    wire [15:0] pdata;
    ui_screen #(.MAXLEN(MAXLEN)) u_screen (
        .px(px), .py(py), .state(state), .digit(digit),
        .msg(msg), .msg_len(msg_len), .rmsg(rmsg), .rmsg_len(rmsg_len),
        .role_rx(role_rx), .note(note),
        .rx_log(rx_log), .rx_n(rx_n),
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
    // [15:11] msg_len  [10] note  [9] left click  [8:5] digit  [4] busy  [3] has_ink  [2:0] state
    assign led = {msg_len, (note != 2'd0), m_left, digit, busy_i, has_ink, state};
endmodule