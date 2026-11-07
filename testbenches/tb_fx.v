`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_fx.v  (Khushi) - renders the visual effects to image files
//
// Drives ui_screen + fx_engine through the sender and receiver flows (the
// switching My_Top_Module does is copied by hand here) and saves 24 frames as
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
  reg link_busy = 0, link_ok = 0, rx_new = 0, replay = 0, enc_go = 0;
  reg [63:0] cipher_hex = 64'h0;  reg show_cipher = 0, dec_go = 0;
  reg oink = 0;

  ui_screen #(.MAXLEN(16)) ui (.px(px_w), .py(py), .state(state), .digit(digit),
     .msg(msg), .msg_len(msg_len), .rx_log(rx_log), .rx_n(rx_n), .rx_hex(rx_hex),
     .role_kb(role_kb), .blink(1'b0), .note(2'd0),
     .link_ok(link_ok), .link_fail(1'b0), .cur_x(cur_x), .cur_y(cur_y),
     .oink(oink), .has_ink(1'b0), .bxmin(7'd0), .bxmax(7'd0), .bymin(6'd0), .bymax(6'd0),
     .toolbar_valid(1'b0), .toolbar_pdata(16'd0), .pdata(ui_pdata));
  fx_engine #(.MAXLEN(16), .FRAME_DIV(40000)) fx (.clk(clk), .rst(rst), .en(en), .style(style),
     .px(px), .py(py), .px_w(px_w), .ui_pdata(ui_pdata), .pdata(pdata),
     .state(state), .digit(digit), .rx_log(rx_log), .rx_n(rx_n), .rx_hex(rx_hex),
     .grid(grid), .cur_x(cur_x), .cur_y(cur_y), .brush_sel(bsel),
     .link_busy(link_busy), .link_ok(link_ok), .rx_new(rx_new), .replay(replay), .enc_go(enc_go),
     .cipher_hex(cipher_hex), .show_cipher(show_cipher), .dec_go(dec_go));

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

    // ---------------- SENDER (mouse board) ----------------
    state = 0; frames(2); snap("frames/01_draw_brush.ppm");
    state = 2; frames(8); snap("frames/02_result_drop.ppm"); frames(40); snap("frames/03_result_settled.ppm");
    state = 3; msg = "1284"; msg_len = 4; frames(45); snap("frames/04_msg_before_send.ppm");
    @(negedge clk) enc_go = 1; @(negedge clk) enc_go = 0; link_busy = 1;           // btnC
    frames(20); snap("frames/05_send_rain.ppm");
    link_busy = 0; @(negedge clk) link_ok = 1;                                       // delivered
    cipher_hex = 64'hA3F_0C7_E19_4B2_6; show_cipher = 1;                              // real ct shown
    frames(40); snap("frames/06_send_rain_ends.ppm");
    frames(40); snap("frames/07_fireworks_over_cipher.ppm");
    frames(60); snap("frames/08_sender_cipher_view.ppm");
    show_cipher = 0; frames(2); snap("frames/09_sender_btnR_plain.ppm");            // btnR

    // ---------------- RECEIVER (sw12 up) ----------------
    link_ok = 0; state = 4; rx_n = 0; frames(45); snap("frames/10_rx_empty_no_rain.ppm");
    cipher_hex = 64'hA3F_0C7_E19_4B2_6; show_cipher = 1;                              // ciphertext arrived
    frames(4); snap("frames/11_rx_cipher_arrived.ppm");
    style = 0;
    @(negedge clk) dec_go = 1; @(negedge clk) dec_go = 0;                            // btnC: decrypt
    show_cipher = 0; rx_log = "1284"; rx_n = 4;                                      // plaintext released
    frames(20); snap("frames/12_decrypt_cipher.ppm");
    frames(12); snap("frames/13_decrypt_burst.ppm");
    frames(20); snap("frames/14_decrypt_scattered.ppm");
    frames(20); snap("frames/15_decrypt_assemble.ppm");
    frames(20); snap("frames/16_decrypt_assemble_b.ppm");
    frames(40); snap("frames/17_decrypted_fireworks.ppm");
    frames(20); snap("frames/18_decrypted_fireworks_b.ppm");
    frames(60); snap("frames/19_decrypted_plain.ppm");
    style = 1; pulse_replay; frames(20); snap("frames/20_replay_scramble.ppm");      // btnU
    frames(60);
    show_cipher = 1; rx_n = 0; frames(2); snap("frames/21_rx_btnR_cipher.ppm");     // btnR
    en = 0; frames(2); snap("frames/22_fx_off_cipher_still.ppm");
    en = 1; show_cipher = 0; rx_n = 4; state = 3; frames(3); snap("frames/23_slide.ppm");
    en = 0; state = 2; frames(2); snap("frames/24_fx_off_result.ppm");
    $display("done at %0t", $time);
    $finish;
  end
endmodule
