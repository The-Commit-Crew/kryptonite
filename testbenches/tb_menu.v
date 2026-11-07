`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_menu.v  (Khushi) - renders the start-up menu and the restyled toolbar
//
// Drives ui_menu through splash -> SELECT MODE -> RECEIVER options and checks
// the mode it ends in, then renders ui_screen + ui_buttons (toolbar) for the
// sender MSG screen and the receiver RX screen. Saves PPM frames in frames/;
// run testbenches/fx_frames.py on that folder for a contact sheet.
//////////////////////////////////////////////////////////////////////////////
module tb_menu;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;
  reg u = 0, d = 0, l = 0, c = 0, r = 0;
  reg [6:0] px = 0; reg [5:0] py = 0;
  wire active, listen, selft; wire [15:0] mp;
  ui_menu #(.FRAME_DIV(2000)) m (.clk(clk), .rst(rst), .p_up(u), .p_down(d), .p_left(l),
     .p_confirm(c), .p_next(r), .px(px), .py(py), .active(active), .pdata(mp),
     .mode_listen(listen), .mode_self(selft));

  // toolbar + screen
  reg [2:0] st = 3; reg rxr = 0, txv = 0, selfm = 0; reg [6:0] mx = 15; reg [5:0] my = 58; reg ml = 0;
  wire [6:0] cx; wire [5:0] cyy; wire lft, rgt, tv; wire [15:0] tp, up;
  wire cs, cc, cr, ccl, cn, pok, eok;
  ui_buttons #(.REPEAT_DIV(4), .FLASH_DIV(3000)) b (.clk(clk), .rst(rst), .role_kb(1'b0), .debug_en(1'b0),
     .state(st), .rx_role(rxr), .tx_ct_view(txv), .self_mode(selfm),
     .mouse_x(mx), .mouse_y(my), .mouse_left(ml), .mouse_right(1'b0),
     .btn_u_level(1'b0), .btn_c_level(1'b0), .btn_l_level(1'b0), .btn_r_level(1'b0), .btn_d_level(1'b0),
     .px(px), .py(py), .cur_x(cx), .cur_y(cyy), .left(lft), .right(rgt),
     .click_submit(cs), .click_confirm(cc), .click_retry(cr), .click_clear(ccl), .click_next(cn),
     .paint_ok(pok), .erase_ok(eok), .toolbar_valid(tv), .toolbar_pdata(tp));
  ui_screen #(.MAXLEN(16)) s (.px(px), .py(py), .state(st), .digit(4'd7),
     .msg(128'h34_32_31), .msg_len(5'd3), .rx_log(128'd0), .rx_n(5'd0), .rx_hex(1'b0),
     .role_kb(1'b0), .blink(1'b0), .note(2'd0), .link_ok(1'b1), .link_fail(1'b0),
     .cur_x(cx), .cur_y(cyy), .oink(1'b0), .has_ink(1'b0), .bxmin(7'd0), .bxmax(7'd0),
     .bymin(6'd0), .bymax(6'd0), .toolbar_valid(tv), .toolbar_pdata(tp), .pdata(up));

  integer f, x, y, errors = 0;
  reg use_menu = 1;
  task snap; input [8*40-1:0] name;
    begin
      f = $fopen(name, "w"); $fwrite(f, "P3\n96 64\n255\n");
      for (y = 0; y < 64; y = y + 1) for (x = 0; x < 96; x = x + 1) begin
        px = x; py = y; #1;
        if (use_menu) $fwrite(f, "%0d %0d %0d\n", {mp[15:11],mp[15:13]}, {mp[10:5],mp[10:9]}, {mp[4:0],mp[4:2]});
        else          $fwrite(f, "%0d %0d %0d\n", {up[15:11],up[15:13]}, {up[10:5],up[10:9]}, {up[4:0],up[4:2]});
      end
      $fclose(f);
    end
  endtask
  task tick(input integer n); begin repeat (n * 2000) @(posedge clk); end endtask
  `define PRESS(sig) begin @(negedge clk) sig = 1; @(negedge clk) sig = 0; @(negedge clk); end
  task check(input [8*40-1:0] name, input cond);
    begin if (cond) $display("  ok   %0s", name); else begin $display("  FAIL %0s", name); errors = errors + 1; end end
  endtask

  initial begin
    repeat (5) @(posedge clk); rst = 0;
    tick(3);  snap("frames/01_splash_a.ppm");
    tick(20); snap("frames/02_splash_b.ppm");
    tick(24); snap("frames/03_splash_c.ppm");
    check("splash shown after reset", active && !listen && !selft);
    `PRESS(r) tick(1); snap("frames/04_mode_sender.ppm");
    `PRESS(d) tick(1); snap("frames/05_mode_receiver.ppm");
    `PRESS(c) tick(1); snap("frames/06_rx_listen.ppm");
    `PRESS(d) tick(1); snap("frames/07_rx_selftest.ppm");
    `PRESS(l) tick(1); check("btnL goes back to MODE", active && m.ms == 2'd1 && m.sel == 1'b1);
    `PRESS(c) `PRESS(d) `PRESS(c)
    check("SELF TEST picked", !active && selft && !listen);
    rst = 1; repeat (3) @(posedge clk); rst = 0; repeat (3) @(posedge clk);
    check("reset returns to the splash", active && !selft);
    `PRESS(c) `PRESS(c)
    check("SENDER picked", !active && !selft && !listen);
    rst = 1; repeat (3) @(posedge clk); rst = 0;
    `PRESS(r) `PRESS(u) `PRESS(r) `PRESS(r)
    check("LISTEN picked", !active && listen && !selft);

    // toolbar
    use_menu = 0;
    st = 3; txv = 0; mx = 50; my = 30; snap("frames/08_msg_toolbar.ppm");
    mx = 15; my = 58; #1 snap("frames/09_msg_hover_send.ppm");
    txv = 1; mx = 80; snap("frames/10_msg_hover_plain.ppm");
    @(negedge clk) ml = 1; @(negedge clk) ml = 0; repeat (5) @(posedge clk);
    snap("frames/11_msg_click_flash.ppm");
    st = 4; rxr = 1; mx = 15; snap("frames/12_rx_listen_toolbar.ppm");
    rxr = 0; selfm = 1; mx = 50; my = 30; snap("frames/13_rx_selftest_toolbar.ppm");
    if (errors == 0) $display("ALL MENU TESTS PASSED"); else $display("%0d MENU TEST(S) FAILED", errors);
    $finish;
  end
endmodule
