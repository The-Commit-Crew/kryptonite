`timescale 1ns / 1ps
module tb_ui_screen;
    reg [6:0] px = 0;
    reg [5:0] py = 0;
    reg [2:0] state = 0;
    reg [3:0] digit = 0;
    reg [63:0] msg = 0, rmsg = 0;
    reg [4:0] msg_len = 0, rmsg_len = 0;
    reg role_rx = 0;
    reg [1:0] note = 0;
    reg [127:0] rx_log = 0;
    reg [4:0] rx_n = 0;
    reg link_ok = 0, link_fail = 0;
    reg [6:0] cur_x = 50;
    reg [5:0] cur_y = 30;
    reg oink = 0, has_ink = 0;
    reg [6:0] bxmin = 10, bxmax = 20;
    reg [5:0] bymin = 10, bymax = 20;
    wire [15:0] pdata;
    integer errors = 0;
    integer n, n7, n1;

    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, CYAN = 16'h07FF, YELLOW = 16'hFFE0;

    ui_screen #(.MAXLEN(16)) dut (
        .px(px), .py(py), .state(state), .digit(digit),
        .msg(msg), .msg_len(msg_len), .rmsg(rmsg), .rmsg_len(rmsg_len),
        .role_rx(role_rx), .note(note), .rx_log(rx_log), .rx_n(rx_n),
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
        tally(12, 83, 48, 54, GREEN, n);  must_have("hint green", n);
        tally(12, 83, 48, 54, RED, n);    must_not("hint not red", n);
        digit = 1;
        tally(38, 61, 10, 37, WHITE, n1); must_have("big 1", n1);
        if (n7 == n1) begin errors = errors + 1; $display("FAIL: digit 7 and 1 look the same"); end
        msg_len = 16;
        tally(12, 83, 48, 54, RED, n);    must_have("FULL hint red", n);
        tally(12, 83, 48, 54, GREEN, n);  must_not("FULL not green", n);

        //================================================ MSG, sender role
        state = 3; role_rx = 0; msg = 64'h973; msg_len = 3;
        rmsg = 0; rmsg_len = 0; link_ok = 0; link_fail = 0;
        tally(0, 35, 14, 27, WHITE, n);   must_have("row1 digits", n);
        tally(48, 95, 14, 27, WHITE, n);  must_not("row1 empty slots", n);
        tally(0, 95, 32, 45, WHITE, n);   must_not("row2 empty", n);
        tally(0, 35, 0, 6, YELLOW, n);    must_have("MSG header", n);
        tally(0, 95, 54, 60, GREEN, n);   must_have("MSG hint", n);
        tally(66, 89, 0, 6, GREEN, n);    must_not("no status green", n);
        tally(66, 89, 0, 6, RED, n);      must_not("no status red", n);
        link_ok = 1;
        tally(66, 89, 0, 6, GREEN, n);    must_have("OK green", n);
        tally(66, 89, 0, 6, RED, n);      must_not("OK not red", n);
        link_ok = 0; link_fail = 1;
        tally(66, 89, 0, 6, RED, n);      must_have("FAIL red", n);
        tally(66, 89, 0, 6, GREEN, n);    must_not("FAIL not green", n);
        link_fail = 0;
        msg = 64'hFEDCBA9876543210; msg_len = 16;
        tally(0, 95, 32, 45, WHITE, n);   must_have("row2 full", n);

        //================================================ MSG, receiver role
        role_rx = 1; msg_len = 3; msg = 64'h973; rmsg = 0; rmsg_len = 0;
        tally(0, 95, 14, 27, WHITE, n);   must_not("rx role: nothing yet", n);
        rmsg = 64'h15; rmsg_len = 2;
        tally(0, 23, 14, 27, WHITE, n);   must_have("rx role: 2 digits", n);
        tally(36, 95, 14, 27, WHITE, n);  must_not("rx role: rest empty", n);
        role_rx = 0;

        //================================================ RX screen
        state = 4; rx_n = 0; rx_log = 0;
        tally(15, 80, 11, 48, WHITE, n);  must_not("RX empty log", n);
        rx_log[7:0] = 8'h03; rx_log[15:8] = 8'h07; rx_log[23:16] = 8'h09;
        rx_n = 3;
        tally(15, 80, 11, 17, WHITE, n);  must_have("RX row 0", n);
        tally(15, 80, 21, 27, WHITE, n);  must_not("RX row 1 empty", n);
        rx_log = {16{8'hA5}}; rx_n = 16;
        tally(15, 80, 41, 47, WHITE, n);  must_have("RX row 3", n);
        tally(0, 35, 0, 6, YELLOW, n);    must_have("RX header", n);
        tally(12, 83, 54, 60, GREEN, n);  must_have("RX hint", n);
        link_ok = 1;
        tally(66, 89, 0, 6, GREEN, n);    must_have("RX OK green", n);
        link_ok = 0; link_fail = 1;
        tally(66, 89, 0, 6, RED, n);      must_have("RX FAIL red", n);

        if (errors == 0) $display("PASS: tb_ui_screen");
        else             $display("FAIL: tb_ui_screen, %0d errors", errors);
        $finish;
    end
endmodule