`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_fx.v  (Khushi) - renders the visual effects to image files
//
// Drives ui_screen + fx_engine through every effect and saves 24 frames as
// PPM images in a folder called frames/ (create it first, next to where the
// simulator runs). Then run:  py testbenches/fx_frames.py <that folder>
// to get contact_sheet.png with all frames side by side.
// FRAME_DIV is shrunk to 40,000 clocks so a "frame" is 0.4 ms instead of
// 16.7 ms; the effects behave the same, just faster.
// Needs: fx_engine.v, fx_particles.v, fx_spring.v, ui_screen.v, text_line.v,
// font_rom.v. In Vivado: run all (about 140 ms of simulated time).
//////////////////////////////////////////////////////////////////////////////
module tb_fx;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, en = 1, style = 0;
  reg [6:0] px = 0; reg [5:0] py = 0;
  wire [6:0] px_w; wire [15:0] ui_pdata, pdata;
  reg [2:0] state = 0; reg role_kb = 0; reg [3:0] digit = 7; reg rx_hex = 0;
  reg [127:0] msg = 0, rx_log = 0; reg [4:0] msg_len = 0, rx_n = 0;
  reg [319:0] grid = 0; reg [6:0] cur_x = 40; reg [5:0] cur_y = 30; reg [1:0] bsel = 2;
  reg link_busy = 0, link_ok = 0, rx_new = 0, replay = 0;
  reg oink = 0;

  ui_screen #(.MAXLEN(16)) ui (.px(px_w), .py(py), .state(state), .digit(digit),
     .msg(msg), .msg_len(msg_len), .rx_log(rx_log), .rx_n(rx_n), .rx_hex(rx_hex),
     .role_kb(role_kb), .blink(1'b0), .note(2'd0),
     .link_ok(link_ok), .link_fail(1'b0), .cur_x(cur_x), .cur_y(cur_y),
     .oink(oink), .has_ink(1'b0), .bxmin(7'd0), .bxmax(7'd0), .bymin(6'd0), .bymax(6'd0), .pdata(ui_pdata));
  fx_engine #(.MAXLEN(16), .FRAME_DIV(40000)) fx (.clk(clk), .rst(rst), .en(en), .style(style),
     .px(px), .py(py), .px_w(px_w), .ui_pdata(ui_pdata), .pdata(pdata),
     .state(state), .digit(digit), .rx_log(rx_log), .rx_n(rx_n), .rx_hex(rx_hex),
     .grid(grid), .cur_x(cur_x), .cur_y(cur_y), .brush_sel(bsel),
     .link_busy(link_busy), .link_ok(link_ok), .rx_new(rx_new), .replay(replay));

  integer f, i, x, y;
  task snap; input [8*40-1:0] name;
    begin
      @(posedge fx.tick); repeat (14000) @(posedge clk);   // let the particle frame finish
      f = $fopen(name, "w");
      $fwrite(f, "P3\n96 64\n255\n");
      for (y = 0; y < 64; y = y + 1) for (x = 0; x < 96; x = x + 1) begin
        px = x; py = y; @(posedge clk); @(posedge clk); #1;
        $fwrite(f, "%0d %0d %0d\n", {pdata[15:11], pdata[15:13]}, {pdata[10:5], pdata[10:9]}, {pdata[4:0], pdata[4:2]});
      end
      $fclose(f);
    end
  endtask
  task frames; input integer n; begin repeat (n) @(posedge fx.tick); end endtask
  task pulse_rx; begin @(negedge clk) rx_new = 1; @(negedge clk) rx_new = 0; end endtask
  task pulse_replay; begin @(negedge clk) replay = 1; @(negedge clk) replay = 0; end endtask

  initial begin
    // grid test pattern: a "7" shape with greys
    for (i = 0; i < 64; i = i + 1) grid[i*5 +: 5] = 0;
    for (i = 1; i < 7; i = i + 1) grid[(0*8+i)*5 +: 5] = 16;
    grid[(1*8+6)*5 +: 5] = 12; grid[(2*8+5)*5 +: 5] = 14; grid[(3*8+5)*5 +: 5] = 8;
    grid[(4*8+4)*5 +: 5] = 16; grid[(5*8+4)*5 +: 5] = 10; grid[(6*8+3)*5 +: 5] = 16; grid[(7*8+3)*5 +: 5] = 6;
    repeat (5) @(posedge clk); rst = 0;

    // DRAW: brush outline (5x5) around the cursor
    state = 0; frames(2); snap("frames/01_draw_brush.ppm");
    // WAIT: spinner
    state = 1; frames(5); snap("frames/02_wait_spin_a.ppm"); frames(6); snap("frames/03_wait_spin_b.ppm");
    // RESULT: preview + digit drop
    state = 2; frames(1); snap("frames/04_result_drop_early.ppm"); frames(8); snap("frames/05_result_drop_mid.ppm");
    frames(40); snap("frames/06_result_settled.ppm");
    // RX screen, nothing received yet: rain
    state = 4; rx_n = 0; frames(45); snap("frames/07_rx_rain.ppm"); frames(10); snap("frames/08_rx_rain_b.ppm");
    // message arrives: scramble style ("hello kryptonite", 16 bytes, byte 0 first)
    rx_log = "etinotpyrk olleh"; rx_n = 16;
    style = 0; pulse_rx;
    frames(3);  snap("frames/09_scramble_t03.ppm");
    frames(12); snap("frames/10_scramble_t15.ppm");
    frames(15); snap("frames/11_scramble_t30.ppm");
    frames(80); snap("frames/12_scramble_done.ppm");
    // particle assemble style (replay)
    style = 1; pulse_replay;
    frames(2);  snap("frames/13_assemble_t02.ppm");
    frames(10); snap("frames/14_assemble_t12.ppm");
    frames(10); snap("frames/15_assemble_t22.ppm");
    frames(12); snap("frames/16_assemble_t34.ppm");
    frames(40); snap("frames/17_assemble_done.ppm");
    // sender (keyboard board COMPOSE screen): delivery fireworks
    state = 5; role_kb = 1; msg = "IH"; msg_len = 2; frames(45);
    @(negedge clk) link_ok = 1;
    frames(4);  snap("frames/18_fireworks_t04.ppm");
    frames(10); snap("frames/19_fireworks_t14.ppm");
    frames(14); snap("frames/20_fireworks_t28.ppm");
    frames(20); snap("frames/21_fireworks_t48.ppm");
    // slide-in: go to the RX screen
    link_ok = 0; state = 4; frames(3); snap("frames/22_slide_t03.ppm"); frames(6); snap("frames/23_slide_t09.ppm");
    // effects off: plain UI
    en = 0; state = 2; frames(2); snap("frames/24_fx_off_result.ppm");
    $display("done at %0t", $time);
    $finish;
  end
endmodule
