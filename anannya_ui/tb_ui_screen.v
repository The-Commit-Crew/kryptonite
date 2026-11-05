`timescale 1ns / 1ps
module tb_ui_screen;
    reg [6:0] px = 0;
    reg [5:0] py = 0;
    reg [2:0] state = 0;
    reg [3:0] digit = 0;
    reg [127:0] msg = 0, rx_log = 0;
    reg [4:0] msg_len = 0, rx_n = 0;
    reg rx_hex = 0, role_kb = 0, blink = 0;
    reg [1:0] note = 0;
    reg link_ok = 0, link_fail = 0;
    reg [6:0] cur_x = 50;
    reg [5:0] cur_y = 30;
    reg oink = 0, has_ink = 0;
    reg [6:0] bxmin = 10, bxmax = 20;
    reg [5:0] bymin = 10, bymax = 20;
    wire [15:0] pdata;
    integer errors = 0;
    integer n, n7, n1, na, nb;

    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, CYAN = 16'h07FF, YELLOW = 16'hFFE0;

    ui_screen #(.MAXLEN(16)) dut (
        .px(px), .py(py), .state(state), .digit(digit),
        .msg(msg), .msg_len(msg_len), .rx_log(rx_log), .rx_n(rx_n),
        .rx_hex(rx_hex), .role_kb(role_kb), .blink(blink), .note(note),
        .link_ok(link_ok), .link_fail(link_fail),
        .cur_x(cur_x), .cur_y(cur_y), .oink(oink), .has_ink(has_ink),
        .bxmin(bxmin), .bxmax(bxmax), .bymin(bymin), .bymax(bymax),
        .pdata(pdata));

    // count the pixels of one colour inside a rectangle
    task tally;
        input integer x0, x1, y0, y1;
        input [15:0] col;
        output integer cnt;
        integer x, y;
        begin
            cnt = 0;
            for (y = y0; y <= y1; y = y + 1)
                for (x = x0; x <= x1; x = x + 1) begin
                    px = x; py = y; #1;
                    if (pdata === col) cnt = cnt + 1;
                end
        end
    endtask

    task px_is;
        input [255:0] what;
        input integer x, y;
        input [15:0] col;
        begin
            px = x; py = y; #1;
            if (pdata !== col) begin
                errors = errors + 1;
                $display("FAIL %0s: pixel (%0d,%0d) = %h, want %h", what, x, y, pdata, col);
            end
        end
    endtask

    task must_have;
        input [255:0] what;
        input integer v;
        begin
            if (v <= 0) begin errors = errors + 1; $display("FAIL %0s: expected pixels, got %0d", what, v); end
        end
    endtask

    task must_not;
        input [255:0] what;
        input integer v;
        begin
            if (v != 0) begin errors = errors + 1; $display("FAIL %0s: expected none, got %0d", what, v); end
        end
    endtask

    initial begin
        #1;
        //================================================ DRAW
        state = 0;
        px_is("cursor centre", 50, 30, RED);
        px_is("cursor left",   49, 30, RED);
        px_is("cursor right",  51, 30, RED);
        px_is("cursor up",     50, 29, RED);
        px_is("cursor down",   50, 31, RED);
        px_is("not cursor",    52, 30, BLACK);
        px_is("diagonal",      51, 31, BLACK);
        px_is("blank canvas",  10, 10, BLACK);
        oink = 1;
        px_is("ink",           10, 10, WHITE);
        px_is("cursor over ink", 50, 30, RED);
        oink = 0;
        has_ink = 1;
        px_is("box edge top",  15, 10, GREEN);
        px_is("box edge left", 10, 15, GREEN);
        px_is("box inside",    15, 15, BLACK);
        has_ink = 0;
        px_is("no box",        10, 15, BLACK);
        note = 1;
        tally(0, 29, 0, 6, YELLOW, n);  must_have("EMPTY note", n);
        note = 0;
        tally(0, 29, 0, 6, YELLOW, n);  must_not("no note", n);

        //================================================ WAIT
        state = 1; note = 1;
        tally(24, 71, 25, 38, CYAN, n);   must_have("WAIT text", n);
        tally(0, 95, 0, 63, WHITE, n);    must_not("WAIT no white", n);
        tally(0, 95, 0, 63, RED, n);      must_not("WAIT no cursor", n);
        tally(0, 29, 0, 6, YELLOW, n);    must_not("WAIT no note", n);
        note = 0;

        //================================================ RESULT
        state = 2; digit = 7; msg_len = 3;
        tally(38, 61, 10, 37, WHITE, n7); must_have("big 7", n7);
        digit = 1;
        tally(38, 61, 10, 37, WHITE, n1); must_have("big 1", n1);
        if (n7 == n1) begin errors = errors + 1; $display("FAIL: digit 7 and 1 look the same"); end
        tally(0, 95, 54, 60, GREEN, n);   must_have("RESULT hint green", n);
        tally(0, 95, 54, 60, RED, n);     must_not("RESULT hint not red", n);
        msg_len = 16;
        tally(0, 95, 54, 60, RED, n);     must_have("RESULT FULL hint red", n);
        tally(0, 95, 54, 60, GREEN, n);   must_not("RESULT FULL not green", n);

        //================================================ MSG (mouse board, our digits as ASCII)
        state = 3; msg = {104'd0, "3", "2", "1"}; msg_len = 3;
        link_ok = 0; link_fail = 0;
        tally(0, 41, 0, 6, YELLOW, n);    must_have("MSG header", n);
        tally(0, 35, 14, 27, WHITE, n);   must_have("MSG row1 chars", n);
        tally(48, 95, 14, 27, WHITE, n);  must_not("MSG row1 empty slots", n);
        tally(0, 95, 32, 45, WHITE, n);   must_not("MSG row2 empty", n);
        tally(0, 95, 54, 60, GREEN, n);   must_have("MSG hint", n);
        tally(66, 89, 0, 6, GREEN, n);    must_not("MSG no status green", n);
        tally(66, 89, 0, 6, RED, n);      must_not("MSG no status red", n);
        link_ok = 1;
        tally(66, 89, 0, 6, GREEN, n);    must_have("MSG OK green", n);
        tally(66, 89, 0, 6, RED, n);      must_not("MSG OK not red", n);
        link_ok = 0; link_fail = 1;
        tally(66, 89, 0, 6, RED, n);      must_have("MSG FAIL red", n);
        tally(66, 89, 0, 6, GREEN, n);    must_not("MSG FAIL not green", n);
        link_fail = 0;
        msg = {16{8'h58}}; msg_len = 16;
        tally(0, 95, 32, 45, WHITE, n);   must_have("MSG row2 full", n);
        // lower case draws exactly like upper case
        msg = {120'd0, "a"}; msg_len = 1;
        tally(0, 11, 14, 27, WHITE, na);
        msg = {120'd0, "A"};
        tally(0, 11, 14, 27, WHITE, nb);
        must_have("letter drawn", na);
        if (na != nb) begin errors = errors + 1; $display("FAIL: 'a' and 'A' look different"); end

        //================================================ COMPOSE (keyboard board)
        state = 5; role_kb = 1; blink = 1;
        msg = {112'd0, "I", "H"}; msg_len = 2;
        tally(0, 41, 0, 6, YELLOW, n);    must_have("COMPOSE header", n);
        tally(0, 23, 14, 27, WHITE, n);   must_have("COMPOSE text", n);
        tally(36, 95, 14, 27, WHITE, n);  must_not("COMPOSE rest empty", n);
        tally(0, 95, 54, 60, GREEN, n);   must_have("COMPOSE hint", n);
        tally(24, 33, 28, 29, CYAN, n);   if (n != 20) begin errors = errors + 1; $display("FAIL: cursor underline = %0d pixels, want 20", n); end
        tally(0, 95, 28, 29, CYAN, n);    if (n != 20) begin errors = errors + 1; $display("FAIL: stray cursor pixels (%0d)", n); end
        blink = 0;
        tally(0, 95, 28, 29, CYAN, n);    must_not("cursor off when blink=0", n);
        blink = 1;
        msg = {16{8'h58}}; msg_len = 10;  // second row, third slot
        tally(24, 33, 46, 47, CYAN, n);   must_have("cursor on row 2", n);
        tally(0, 95, 28, 29, CYAN, n);    must_not("no cursor on row 1", n);
        msg_len = 16;
        tally(0, 95, 28, 29, CYAN, n);    must_not("no cursor when full (row 1)", n);
        tally(0, 95, 46, 47, CYAN, n);    must_not("no cursor when full (row 2)", n);
        link_ok = 1;
        tally(66, 89, 0, 6, GREEN, n);    must_have("COMPOSE OK green", n);
        link_ok = 0;
        role_kb = 0;

        //================================================ RX
        state = 4; rx_n = 0; rx_log = 0; rx_hex = 0;
        tally(0, 41, 0, 6, YELLOW, n);    must_have("RX header", n);
        tally(0, 95, 11, 48, WHITE, n);   must_not("RX empty (text)", n);
        rx_hex = 1;
        tally(0, 95, 11, 48, WHITE, n);   must_not("RX empty (hex)", n);
        rx_log = {104'd0, "!", "I", "H"}; rx_n = 3;
        rx_hex = 0;
        tally(0, 35, 14, 27, WHITE, n);   must_have("RX text row 1", n);
        tally(0, 95, 32, 47, WHITE, n);   must_not("RX text: nothing below", n);
        rx_hex = 1;
        tally(15, 80, 11, 17, WHITE, n);  must_have("RX hex row 0", n);
        tally(0, 95, 32, 47, WHITE, n);   must_not("RX hex: rows 2 and 3 empty", n);
        rx_log = {16{8'hA5}}; rx_n = 16;
        tally(15, 80, 41, 47, WHITE, n);  must_have("RX hex row 3", n);
        rx_hex = 0; rx_log = {16{8'h4D}};
        tally(0, 95, 32, 45, WHITE, n);   must_have("RX text row 2", n);
        tally(0, 95, 54, 60, GREEN, n);   must_have("RX hint (mouse board)", n);
        role_kb = 1;
        tally(0, 95, 54, 60, GREEN, n);   must_have("RX hint (keyboard board)", n);
        role_kb = 0;
        link_ok = 1;
        tally(66, 89, 0, 6, GREEN, n);    must_have("RX OK green", n);
        link_ok = 0; link_fail = 1;
        tally(66, 89, 0, 6, RED, n);      must_have("RX FAIL red", n);
        link_fail = 0;

        //================================================ unused states stay blank
        state = 6;
        px_is("state 6 blank", 10, 10, BLACK);
        px_is("state 6 blank 2", 50, 30, BLACK);

        if (errors == 0) $display("PASS: tb_ui_screen");
        else             $display("FAIL: tb_ui_screen, %0d errors", errors);
        $finish;
    end
endmodule