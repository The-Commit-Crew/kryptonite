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
//   sw[11:8] debug digit, sw[4] loopback, sw[2] RX screen: 1 = text / 0 = hex, sw[0] brush: 0 = 5x5, 1 = 3x3
//   After changing sw[13], press reset (sw[15]).
//   KEYBOARD board: type to compose, Enter = send, Esc = clear, Backspace = delete,
//                   Tab = COMPOSE -> RX text -> RX hex -> COMPOSE, btnD = clear received
//   Khushi's additions:
//     sw[3] up = effects off, sw[5] = decrypt reveal style
//     (0 ciphertext -> particles -> message, 1 scramble-then-lock). Send shows hex rain.
//     Received ciphertext is rebuilt, checked and decrypted in the background.
//   Start-up menu (Khushi, ui_menu): reset shows the KRYPTONITE splash; btnR opens
//     SELECT MODE (btnU/btnD move, btnC picks). RECEIVER then offers LISTEN or
//     SELF TEST (btnL goes back). Hold btnL for 1 s (or reset) to return to the splash.
//   Keyboard board: Enter sends; after a send, Enter shows the plaintext again;
//     on the RX screen (listen / self test) Enter decrypts.
//   Sender / receiver behaviour:
//     Sender:   after a send (hex rain, fireworks) the message rows show the real
//               ciphertext; btnR shows the original digits again.
//     Self test: one board. Draw, send (looped back inside the board), then RX
//               shows your ciphertext and btnC decrypts it.
//     Receiver: stays on the RX screen. A new message shows its real ciphertext;
//               btnC decrypts it (reveal + fireworks); btnR flips between
//               ciphertext and plaintext; btnU replays; btnD clears.
//     btnU on RX replays the reveal; btnU on MSG / COMPOSE corrupts the next packet
//     (demo of the automatic re-send). 7-segment cycles the link counters
//     S (sent) r (received) E (errors) n (re-sends) every 2 s.
//     sw[6] up = ciphertext test: the send button sends the test ciphertext
//     (12 x 128-byte packets) instead; the receiving board rebuilds it and checks
//     it. LEDs then show [15:4] fragments received, [3] sending, [2] all sent,
//     [1] check PASS, [0] check FAIL or send gave up.
module My_Top_Module #(
    parameter SKIP_MENU = 0,                // 1: start straight in sender mode (testbenches)
    parameter ENCRYPT_SEND = 1'b1,
    parameter SIM_MULTIPLIER = 1'b0,
    parameter FIXED_NOISE = 1'b0,
    parameter KEY_DIR = "crypto/keys/board1",
    parameter NOISE_DIR = "crypto/test_vectors/noise",
    parameter ACK_TIMEOUT = 3_000_000,
    parameter BYTE_TMO = 100_000,
    parameter MAX_RETRY = 3,
    parameter [15:0] BAUD_INC = 16'd1208
)(
    input  clk,
    input  [15:0] sw,
    input  btnC, btnU, btnL, btnR, btnD,
    output [15:0] led,
    inout  [1:0]  JA,
    output [7:0]  JC,           // Pmod OLED
    inout  PS2Clk,
    inout  PS2Data,
    output [6:0]  seg,          // 7-segment link stats
    output [3:0]  an,
    output        dp
);
    localparam MAXLEN = 16;

    //---------------------------------------------------------- reset, role, blink
    reg [1:0] rs = 2'b00;
    always @(posedge clk) rs <= {rs[0], sw[15]};
    wire rst = rs[1];

    reg [1:0] rk = 2'b00;                  // sw[13] through a 2-FF synchroniser
    always @(posedge clk) rk <= {rk[0], sw[13]};
    wire role_kb = rk[1];                  // 1 = keyboard board

    reg [1:0] sw4_sync = 2'b00;
    reg [1:0] sw6_sync = 2'b00;
    always @(posedge clk) begin
        sw4_sync <= {sw4_sync[0], sw[4]};
        sw6_sync <= {sw6_sync[0], sw[6]};
    end
    wire sw4_i = sw4_sync[1];
    wire sw6_i = sw6_sync[1];
    reg role_kb_q = 1'b0;
    always @(posedge clk) role_kb_q <= role_kb;
    wire role_changed = role_kb ^ role_kb_q;

    // role comes from the start-up menu (ui_menu, at the end of this file)
    wire menu_active;                      // splash or a menu is on screen
    wire mode_listen, mode_self;           // receiver: listen / self test
    wire role_rx = mode_listen;            // receiver board: always on RX, never sends

    reg [25:0] bcnt = 26'd0;
    always @(posedge clk) bcnt <= bcnt + 26'd1;
    wire blink = bcnt[25];                 // about 3 Hz

    //---------------------------------------------------------- buttons
    wire p_submit, p_confirm, p_retry, p_clear, p_next;
    wire btnU_level, btnC_level, btnL_level, btnR_level, btnD_level;
    debounce d_u (.clk(clk), .btn(btnU), .level(btnU_level), .pulse(p_submit));
    debounce d_c (.clk(clk), .btn(btnC), .level(btnC_level), .pulse(p_confirm));
    debounce d_l (.clk(clk), .btn(btnL), .level(btnL_level), .pulse(p_retry));
    debounce d_d (.clk(clk), .btn(btnD), .level(btnD_level), .pulse(p_clear));
    debounce d_r (.clk(clk), .btn(btnR), .level(btnR_level), .pulse(p_next));
    wire p_next_ctrl;                      // btnR as ui_ctrl sees it (see the views below)
    wire [95:0] tx_ct_head;                // first ciphertext bytes sent (from top_fsm)

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
    wire click_submit, click_confirm, click_retry, click_clear, click_next;
    wire [6:0] ui_cur_x;
    wire [5:0] ui_cur_y;
    wire ui_left, ui_right, paint_ok, erase_ok;
    wire toolbar_valid;
    wire [15:0] toolbar_pdata;
    wire debug_buttons = sw[12] & ~role_kb;
    wire p_submit_ui  = ((p_submit  & ~debug_buttons) | click_submit) & ~menu_active;
    wire p_confirm_ui = ((p_confirm & ~debug_buttons) | click_confirm) & ~menu_active;
    wire p_retry_ui   = ((p_retry   & ~debug_buttons) | click_retry) & ~menu_active;
    wire p_clear_ui   = ((p_clear   & ~debug_buttons) | click_clear) & ~menu_active;
    wire p_next_ui    = ((p_next    & ~debug_buttons) | click_next) & ~menu_active;

    ui_ctrl #(.MAXLEN(MAXLEN)) u_ctrl (
        .clk(clk), .rst(rst | role_changed),
        .p_submit(p_submit_ui), .p_confirm(p_confirm_ui), .p_retry(p_retry_ui),
        .p_clear(p_clear_ui), .p_next(p_next_ctrl),
        .busy_i(busy_i), .pred_valid(pred_valid_i), .pred(pred_i), .empty_i(empty_i),
        .skip_rx(~mode_self),             // sender skips RX; self test visits it
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
    reg  tx_ct_view = 1'b0;                // sender is showing its ciphertext (views below)
    // keyboard Enter, whatever is in the typing buffer
    wire kb_enter   = role_kb & kb_key_v & (kb_key == 8'h0D) & ~menu_active;
    wire kb_on_rx   = role_kb & (role_rx | (kb_view != 2'd0));
    wire send_btn   = ~role_rx & ~menu_active &
                      (role_kb ? (ed_send & ~kb_on_rx & ~tx_ct_view)     // Enter shows plaintext first
                               : (p_confirm_ui & (state == 3'd3)));
    wire ct_mode    = sw6_i;                       // ciphertext test mode (Khushi)
    wire send_req   = send_btn & ~ct_mode;
    wire ct_test_send = send_btn & ct_mode;
    wire retry_req = ~role_rx & p_retry_ui & (role_kb || state == 3'd3);
    // btnD on the RX screen (mouse board) or anywhere on the keyboard board clears the received message
    wire rx_clr_all = ctrl_rxclr | (role_kb & p_clear & ~menu_active) | (role_rx & p_clear_ui);

    // btnU on the MSG / COMPOSE screen: corrupt the next packet (demo of the re-send)
    wire        fault_req = ~role_rx & p_submit_ui & (role_kb ? (kb_view == 2'd0) : (state == 3'd3));
    wire        rx_new;
    wire [11:0] c_sent, c_recv, c_err, c_retry;
    // ciphertext test sender / receiver <-> top_fsm (cipher_link is below)
    wire        ct_busy, ct_we, ct_send, lk_busy, lk_done, lk_fail, lk_rxv;
    wire [6:0]  ct_wa, ct_ra;
    wire [7:0]  ct_wd, ct_len, ct_type, lk_rtype, lk_rlen, lk_rd;

    wire mul_wr_en, mul_start, mul_done;
    wire [7:0] mul_wr_addr, mul_rd_addr;
    wire [11:0] mul_left, mul_right, mul_rd_data;

    top_fsm #(.MAXLEN(MAXLEN), .ENCRYPT_SEND(ENCRYPT_SEND), .FIXED_NOISE(FIXED_NOISE),
              .KEY_DIR(KEY_DIR), .NOISE_DIR(NOISE_DIR), .ACK_TIMEOUT(ACK_TIMEOUT),
              .BYTE_TMO(BYTE_TMO), .MAX_RETRY(MAX_RETRY), .BAUD_INC(BAUD_INC)) u_fsm (
        .clk(clk), .rst(rst), .loopback(sw4_i | mode_self),   // self test: talk to itself
        .rx_pin(JA[1]), .tx_pin(ja_tx),
        .send_req(send_req), .msg_in(out_msg), .msg_len_in(out_len),
        .rx_clear(rx_clr_all),
        .send_ok(link_ok), .send_fail(link_fail), .tx_busy(link_busy),
        .rx_log(rx_log), .rx_n(rx_n),
        .retry_req(retry_req), .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr),
        .mul_left(mul_left), .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
        .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data),
        .fault_inject(fault_req), .rx_new(rx_new),
        .cnt_sent(c_sent), .cnt_recv(c_recv), .cnt_err(c_err), .cnt_retry(c_retry),
        .ct_busy(ct_busy), .ct_we(ct_we), .ct_wa(ct_wa), .ct_wd(ct_wd), .ct_len(ct_len),
        .ct_type(ct_type), .ct_send(ct_send),
        .lk_busy(lk_busy), .lk_done(lk_done), .lk_fail(lk_fail),
        .ct_ra(ct_ra), .lk_rxv(lk_rxv), .lk_rtype(lk_rtype), .lk_rlen(lk_rlen), .lk_rd(lk_rd),
        .tx_ct_head(tx_ct_head));

    //---------------------------------------------------------- ciphertext receive + decrypt (Khushi)
    // Board 2 side: rebuild the 12 x 128-byte ciphertext packets into 768 words,
    // check them, decrypt them (decryption_ntt) and show the message on RX.
    wire [11:0] ct_rx_mask;
    wire        ct_tx_ok, ct_tx_bad, ct_ready, ct_new, ct_pass, ct_fail;
    wire [9:0]  ct_mism;
    wire        dec_busy, dec_new;
    wire [71:0] ct_head;

    wire [MAXLEN*8-1:0] dec_log;
    wire [4:0]  dec_n;
    cipher_link u_ct (
        .clk(clk), .rst(rst), .test_send(ct_test_send), .clear(rx_clr_all),
        .tx_ok(ct_tx_ok), .tx_bad(ct_tx_bad),
        .rx_mask(ct_rx_mask), .ct_ready(ct_ready), .ct_new(ct_new), .ct_head(ct_head),
        .chk_pass(ct_pass), .chk_fail(ct_fail), .chk_mismatch(ct_mism),
        .dec_busy(dec_busy), .msg_new(dec_new), .msg_log(dec_log), .msg_n(dec_n),
        .ct_busy(ct_busy), .ct_we(ct_we), .ct_wa(ct_wa), .ct_wd(ct_wd), .ct_len(ct_len),
        .ct_type(ct_type), .ct_send(ct_send),
        .lk_busy(lk_busy), .lk_done(lk_done), .lk_fail(lk_fail),
        .ct_ra(ct_ra), .lk_rxv(lk_rxv), .lk_rtype(lk_rtype), .lk_rlen(lk_rlen), .lk_rd(lk_rd));

    // RX screen shows the latest message: a decrypted one, or a plaintext one
    // (ENCRYPT_SEND = 0 / old senders). btnD on RX clears both.
    reg dec_show = 1'b0;
    always @(posedge clk) begin
        if (rst || rx_clr_all || rx_new) dec_show <= 1'b0;
        else if (dec_new)                dec_show <= 1'b1;
    end
    wire [MAXLEN*8-1:0] show_log = dec_show ? dec_log : rx_log;
    wire [4:0]          show_n   = dec_show ? dec_n   : rx_n;
    wire                show_new = rx_new | dec_new;

    //---------------------------------------------------------- ciphertext / plaintext views (Khushi)
    // SENDER: after a delivered send the message rows show the real ciphertext
    // (captured from fragment 0 as it was sent); btnR goes back to the digits.
    wire on_send_scr = role_kb ? (kb_view == 2'd0) : (state == 3'd3);
    reg  ok_q2 = 1'b0;
    reg  [4:0] len_q = 5'd0;
    wire tx_flip = ~role_rx & tx_ct_view & on_send_scr &
                   (p_next_ui | kb_enter);                         // btnR / Enter: show the plaintext
    always @(posedge clk) begin
        ok_q2 <= link_ok; len_q <= out_len;
        if (rst || role_rx || send_btn || out_len != len_q || tx_flip) tx_ct_view <= 1'b0;
        else if (link_ok && !ok_q2)                                   tx_ct_view <= 1'b1;
    end
    assign p_next_ctrl = p_next_ui & ~tx_flip;     // that btnR press doesn't change screen

    // RECEIVER: a new ciphertext is shown as ciphertext until btnC decrypts it.
    reg  rx_ct_view = 1'b0;
    // on the RX screen in listen or self-test mode
    wire on_rx_scr = role_rx | (role_kb ? (kb_view != 2'd0) : (state == 3'd4));
    wire rx_ui   = on_rx_scr & (mode_listen | mode_self);
    wire dec_go  = rx_ui & rx_ct_view & dec_show &
                   (p_confirm_ui | kb_enter);                      // btnC / DECRY / Enter: decrypt
    wire rx_flip = mode_listen & dec_show & p_next_ui;             // btnR / FLIP: cipher <-> plain
    always @(posedge clk) begin
        if (rst || rx_clr_all || rx_new || dec_go) rx_ct_view <= 1'b0;
        else if (ct_new)                           rx_ct_view <= 1'b1;
        else if (rx_flip)                          rx_ct_view <= ~rx_ct_view;
    end

    // 16 hex digits of real ciphertext: the first coefficients {w0, w1, ...}
    wire [71:0] tx_words;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : g_txw
            assign tx_words[(5-gi)*12 +: 12] = {tx_ct_head[(2*gi+1)*8 +: 4], tx_ct_head[(2*gi)*8 +: 8]};
        end
    endgenerate
    // RX screen: the received ciphertext; MSG / COMPOSE: the one this board sent
    wire [63:0] cipher_hex  = on_rx_scr ? ct_head[71:8] : tx_words[71:8];
    wire        show_cipher = on_rx_scr ? (rx_ct_view & ct_ready) : tx_ct_view;

    // the plaintext stays hidden (text and hex views) until it has been decrypted
    wire [MAXLEN*8-1:0] view_log = rx_ct_view ? {MAXLEN*8{1'b0}} : show_log;
    wire [4:0]          view_n   = rx_ct_view ? 5'd0 : show_n;

    //---------------------------------------------------------- 7-segment link stats (Khushi)
    // cycles S -> r -> E -> n every 2 seconds, no button needed
    reg [27:0] seg_tmr = 28'd0;
    reg        seg_next = 1'b0;
    always @(posedge clk) begin
        seg_next <= 1'b0;
        if (seg_tmr == 28'd199_999_999) begin seg_tmr <= 28'd0; seg_next <= 1'b1; end
        else seg_tmr <= seg_tmr + 28'd1;
    end
    seg7_stats u_seg (.clk(clk), .rst(rst), .next(seg_next),
                      .cnt_sent(c_sent), .cnt_recv(c_recv), .cnt_err(c_err), .cnt_retry(c_retry),
                      .seg(seg), .an(an), .dp(dp));

    // The FPGA path uses writable forward NTTs, pair multiplication and INTT.
    // SIM_MULTIPLIER retains the behavioral reference for quick UI simulations.
    generate
        if (ENCRYPT_SEND && SIM_MULTIPLIER) begin : simulation_multiplier
            poly_mult_model multiplier (
                .clk(clk), .rst(rst), .wr_en(mul_wr_en), .wr_addr(mul_wr_addr),
                .left_data(mul_left), .right_data(mul_right), .start(mul_start), .done(mul_done),
                .rd_addr(mul_rd_addr), .rd_data(mul_rd_data)
            );
        end else if (ENCRYPT_SEND) begin : hardware_multiplier
            shared_poly_multiplier multiplier (
                .clk(clk), .rst(rst), .wr_en(mul_wr_en), .wr_addr(mul_wr_addr),
                .left_data(mul_left), .right_data(mul_right), .start(mul_start), .done(mul_done),
                .rd_addr(mul_rd_addr), .rd_data(mul_rd_data)
            );
        end else begin : plaintext_multiplier
            assign mul_done = 1'b0;
            assign mul_rd_data = 12'd0;
        end
    endgenerate

    // JA is inout in the master naming: drive pin 0 as TX, pin 1 stays an input
    assign JA[0] = ja_tx;

    //---------------------------------------------------------- vision + ML (Shrikkanth/Khushi)
    wire [12:0] pix;
    wire [6:0]  px;
    wire [5:0]  py;
    wire [6:0] ox;
    wire [5:0] oy;
    wire [6:0] px_w;                       // x shifted by the slide-in effect
    assign ox = px_w;                      // the canvas slides with the screen
    assign oy = py;
    vision_ml u_vml (
        .clk(clk), .rst(rst),
        .cursor_x(ui_cur_x), .cursor_y(ui_cur_y),
        .paint(ui_left & paint_ok & in_draw),
        .erase(ui_right & ~ui_left & erase_ok & in_draw),
        .clear(ctrl_clear | (mid_pulse & in_draw)),
        .brush_sel({~sw[0], sw[0]}),
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

    ui_buttons u_buttons (
        .clk(clk), .rst(rst), .role_kb(role_kb), .debug_en(sw[12]),
        .state(role_rx ? 3'd4 : state), .rx_role(role_rx), .tx_ct_view(tx_ct_view),
        .self_mode(mode_self),
        .mouse_x(cur_x), .mouse_y(cur_y), .mouse_left(m_left), .mouse_right(m_right),
        .btn_u_level(btnU_level), .btn_c_level(btnC_level), .btn_l_level(btnL_level),
        .btn_r_level(btnR_level), .btn_d_level(btnD_level),
        .px(px_w), .py(py), .cur_x(ui_cur_x), .cur_y(ui_cur_y),
        .left(ui_left), .right(ui_right),
        .click_submit(click_submit), .click_confirm(click_confirm),
        .click_retry(click_retry), .click_clear(click_clear), .click_next(click_next),
        .paint_ok(paint_ok), .erase_ok(erase_ok),
        .toolbar_valid(toolbar_valid), .toolbar_pdata(toolbar_pdata));

    //---------------------------------------------------------- the renderer
    wire [2:0] scr_state = menu_active ? 3'd6 :                   // splash / menus
                           role_rx ? 3'd4 :                       // receiver: always RX
                           role_kb ? ((kb_view == 2'd0) ? 3'd5 : 3'd4) : state;
    wire       rx_hex    = role_kb ? (kb_view == 2'd2) : ~sw[2];   // mouse board: sw[2] up = text

    wire [15:0] ui_pdata, fx_pdata, menu_pdata;
    wire [15:0] pdata = menu_active ? menu_pdata : fx_pdata;
    ui_screen #(.MAXLEN(MAXLEN)) u_screen (
        .px(px_w), .py(py), .state(scr_state), .digit(digit),
        .msg(out_msg), .msg_len(out_len),
        .rx_log(view_log), .rx_n(view_n), .rx_hex(rx_hex),
        .role_kb(role_kb), .blink(blink), .note(note),
        .link_ok(link_ok), .link_fail(link_fail),
        .cur_x(ui_cur_x), .cur_y(ui_cur_y),
        .oink(oink), .has_ink(has_ink),
        .bxmin(bxmin), .bxmax(bxmax), .bymin(bymin), .bymax(bymax),
        .toolbar_valid(toolbar_valid), .toolbar_pdata(toolbar_pdata),
        .pdata(ui_pdata));

    //---------------------------------------------------------- effects on top (Khushi)
    fx_engine #(.MAXLEN(MAXLEN)) u_fx (
        .clk(clk), .rst(rst), .en(~sw[3]), .style(sw[5]),
        .px(px), .py(py), .px_w(px_w), .ui_pdata(ui_pdata), .pdata(fx_pdata),
        .state(scr_state), .digit(digit),
        .rx_log(view_log), .rx_n(view_n), .rx_hex(rx_hex),
        .grid(grid), .cur_x(ui_cur_x), .cur_y(ui_cur_y), .brush_sel({~sw[0], sw[0]}),
        .link_busy(link_busy | dec_busy), .link_ok(link_ok), .rx_new(show_new),
        .replay(p_submit_ui & (scr_state == 3'd4)),
        .enc_go(send_btn),
        .cipher_hex(cipher_hex), .show_cipher(show_cipher), .dec_go(dec_go));

    //---------------------------------------------------------- start-up menu (Khushi)
    // hold btnL for 1 s: back to the KRYPTONITE splash and the mode menu
    reg [26:0] home_cnt = 27'd0;
    reg        go_home  = 1'b0;
    always @(posedge clk) begin
        go_home <= 1'b0;
        if (!btnL_level || menu_active || debug_buttons) home_cnt <= 27'd0;   // sw12 uses btnL as a cursor key
        else if (home_cnt == 27'd99_999_999) begin home_cnt <= 27'd0; go_home <= 1'b1; end
        else home_cnt <= home_cnt + 27'd1;
    end

    ui_menu #(.SKIP(SKIP_MENU)) u_menu (
        .clk(clk), .rst(rst), .go_home(go_home),
        .p_up(p_submit), .p_down(p_clear), .p_left(p_retry),
        .p_confirm(p_confirm), .p_next(p_next),
        .px(px), .py(py), .active(menu_active), .pdata(menu_pdata),
        .mode_listen(mode_listen), .mode_self(mode_self));

    Oled_Display u_oled (
        .clk(clk6p25), .reset(rst),
        .frame_begin(), .sending_pixels(), .sample_pixel(),
        .pixel_index(pix), .pixel_data(pdata),
        .cs(JC[0]), .sdin(JC[1]), .sclk(JC[3]), .d_cn(JC[4]),
        .resn(JC[5]), .vccen(JC[6]), .pmoden(JC[7]));
    assign JC[2] = 1'b0;

    //---------------------------------------------------------- LEDs
    // [15:11] message length  [10] note  [9] left click  [8:5] digit  [4] busy  [3] has_ink  [2:0] state
    wire [15:0] led_ui = {out_len, (note != 2'd0), m_left, digit, (busy_i | link_busy), has_ink, state};
    wire [15:0] led_ct = {ct_rx_mask, ct_busy, ct_tx_ok, ct_pass, ct_fail | ct_tx_bad};
    wire [15:0] led_cas;
    wire        cas_active;
    led_cascade u_led_cascade (
        .clk(clk), .rst(rst), .trig_send(link_busy), .trig_recv(dec_go),
        .role(role_rx), .led_cas(led_cas), .active(cas_active));
    assign led = ct_mode ? led_ct : (cas_active ? led_cas : led_ui);
endmodule
