`timescale 1ns / 1ps
module tb_ps2_kbd;
    localparam HP  = 400;                 // half a bit period in clocks (4 us, faster than a real keyboard)
    localparam TMO = 5000;                // receiver stall timeout in clocks

    reg clk = 0, rst = 1;
    reg ps2_clk = 1, ps2_data = 1;
    wire [7:0] code, key;
    wire code_v, rx_err, key_v;
    wire [127:0] msg;
    wire [4:0] len;
    wire send;
    integer errors = 0, n_send = 0, n_err = 0, k, e0;

    always #5 clk = ~clk;

    ps2_kbd_rx #(.TMO(TMO)) u_rx (
        .clk(clk), .rst(rst), .ps2_clk(ps2_clk), .ps2_data(ps2_data),
        .data(code), .valid(code_v), .err(rx_err));
    kbd_decode u_dec (
        .clk(clk), .rst(rst), .code(code), .code_valid(code_v),
        .key(key), .key_valid(key_v));
    msg_edit #(.MAXLEN(16)) u_ed (
        .clk(clk), .rst(rst), .key(key), .key_valid(key_v),
        .msg(msg), .len(len), .send(send));

    always @(posedge clk) begin
        if (send)   n_send <= n_send + 1;
        if (rx_err) n_err  <= n_err + 1;
    end

    task wait_clks; input integer n; begin repeat (n) @(posedge clk); end endtask

    // send the first nbits of an 11-bit frame: data set up, clock low for 2*HP, clock high
    task ps2_bits;
        input [10:0] f;
        input integer nbits;
        integer i;
        begin
            for (i = 0; i < nbits; i = i + 1) begin
                ps2_data = f[i]; wait_clks(HP);
                ps2_clk = 0;     wait_clks(2*HP);
                ps2_clk = 1;     wait_clks(HP);
            end
            ps2_data = 1;
        end
    endtask

    // one byte: start(0), 8 data bits LSB first, odd parity, stop(1)
    task ps2_byte;
        input [7:0] b;
        input par_ok;
        reg [10:0] f;
        begin
            f = {1'b1, (par_ok ? ~(^b) : (^b)), b, 1'b0};
            ps2_bits(f, 11);
            wait_clks(HP);
        end
    endtask

    task make; input [7:0] c; begin ps2_byte(c, 1'b1); end endtask
    task brk;  input [7:0] c; begin ps2_byte(8'hF0, 1'b1); ps2_byte(c, 1'b1); end endtask
    task tap;  input [7:0] c; begin make(c); brk(c); end endtask
    task settle; begin wait_clks(100); end endtask

    task expect_len;
        input integer want;
        input [255:0] what;
        begin
            if (len !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: len = %0d, want %0d", what, len, want);
            end
        end
    endtask

    task expect_char;
        input integer idx;
        input [7:0] want;
        input [255:0] what;
        begin
            if (msg[idx*8 +: 8] !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: char %0d = %h, want %h", what, idx, msg[idx*8 +: 8], want);
            end
        end
    endtask

    task expect_sends;
        input integer want;
        input [255:0] what;
        begin
            if (n_send !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: sends = %0d, want %0d", what, n_send, want);
            end
        end
    endtask

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        wait_clks(50);

        // ---- letters, Shift, digits ----
        tap(8'h1C); settle;                                   expect_len(1, "a");        expect_char(0, "a", "a");
        make(8'h12); tap(8'h32); brk(8'h12); settle;          expect_len(2, "Shift+B");  expect_char(1, "B", "Shift+B");
        tap(8'h16); settle;                                   expect_len(3, "1");        expect_char(2, "1", "1");
        make(8'h12); tap(8'h16); brk(8'h12); settle;          expect_len(4, "Shift+1");  expect_char(3, "!", "Shift+1");
        tap(8'h29); settle;                                   expect_len(5, "space");    expect_char(4, " ", "space");

        // ---- Backspace, right Shift, ignored keys ----
        tap(8'h66); settle;                                   expect_len(4, "Backspace");
        make(8'h59); tap(8'h4C); brk(8'h59); settle;          expect_len(5, "RShift+;");  expect_char(4, ":", "RShift+;");
        tap(8'h4C); settle;                                   expect_len(5, "; alone ignored");   // also proves Shift was released
        ps2_byte(8'hE0, 1'b1); ps2_byte(8'h75, 1'b1);                                             // extended key (arrow)
        ps2_byte(8'hE0, 1'b1); ps2_byte(8'hF0, 1'b1); ps2_byte(8'h75, 1'b1); settle;
                                                              expect_len(5, "extended key ignored");
        ps2_byte(8'hFA, 1'b1); ps2_byte(8'hAA, 1'b1); settle; expect_len(5, "power-on codes ignored");

        // ---- bad parity, cut-off frame ----
        e0 = n_err;
        ps2_byte(8'h1C, 1'b0); settle;
        if (n_err !== e0 + 1) begin errors = errors + 1; $display("FAIL: bad parity not reported"); end
        expect_len(5, "bad parity ignored");
        ps2_bits({1'b1, ~(^8'h1C), 8'h1C, 1'b0}, 5);         // only 5 of 11 bits, then silence
        wait_clks(2*TMO);
        tap(8'h21); settle;                                   expect_len(6, "after cut-off frame");  expect_char(5, "c", "after cut-off frame");

        // ---- Tab, Enter, Esc ----
        tap(8'h0D); settle;                                   expect_len(6, "Tab changes nothing");
        expect_sends(0, "no send yet");
        tap(8'h5A); settle;                                   expect_sends(1, "Enter sends");
        expect_len(6, "text stays after Enter");
        tap(8'h76); settle;                                   expect_len(0, "Esc clears");
        tap(8'h5A); settle;                                   expect_sends(1, "Enter on empty does nothing");
        tap(8'h66); settle;                                   expect_len(0, "Backspace on empty");

        // ---- full buffer: 18 keys, only 16 fit ----
        for (k = 0; k < 18; k = k + 1) tap(8'h22);
        settle;
        expect_len(16, "full buffer");
        if (msg !== {16{8'h78}}) begin errors = errors + 1; $display("FAIL: full buffer contents %h", msg); end

        if (errors == 0) $display("PASS: tb_ps2_kbd");
        else             $display("FAIL: tb_ps2_kbd, %0d errors", errors);
        $finish;
    end
endmodule