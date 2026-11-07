`timescale 1ns / 1ps

module tb_ui_buttons;
    reg clk = 0, rst = 1;
    reg role_kb = 0, debug_en = 0;
    reg [2:0] state = 0;
    reg [6:0] mouse_x = 50;
    reg [5:0] mouse_y = 30;
    reg mouse_left = 0, mouse_right = 0;
    reg btn_u_level = 0, btn_c_level = 0, btn_l_level = 0;
    reg btn_r_level = 0, btn_d_level = 0;
    reg [6:0] px = 0;
    reg [5:0] py = 0;
    wire [6:0] cur_x;
    wire [5:0] cur_y;
    wire left, right;
    wire click_submit, click_confirm, click_retry, click_clear, click_next;
    wire paint_ok, erase_ok, toolbar_valid;
    wire [15:0] toolbar_pdata;
    wire [15:0] screen_pdata;
    reg push_confirm = 0;
    wire merged_confirm = click_confirm | push_confirm;
    integer errors = 0;
    integer combined;

    ui_buttons #(.REPEAT_DIV(4), .FLASH_DIV(3)) dut (
        .clk(clk), .rst(rst), .role_kb(role_kb), .debug_en(debug_en), .state(state),
        .mouse_x(mouse_x), .mouse_y(mouse_y), .mouse_left(mouse_left), .mouse_right(mouse_right),
        .btn_u_level(btn_u_level), .btn_c_level(btn_c_level), .btn_l_level(btn_l_level),
        .btn_r_level(btn_r_level), .btn_d_level(btn_d_level), .px(px), .py(py),
        .cur_x(cur_x), .cur_y(cur_y), .left(left), .right(right),
        .click_submit(click_submit), .click_confirm(click_confirm),
        .click_retry(click_retry), .click_clear(click_clear), .click_next(click_next),
        .paint_ok(paint_ok), .erase_ok(erase_ok),
        .toolbar_valid(toolbar_valid), .toolbar_pdata(toolbar_pdata));

    ui_screen #(.MAXLEN(16)) screen_dut (
        .px(px), .py(py), .state(state), .digit(4'd0),
        .msg(128'd0), .msg_len(5'd0), .rx_log(128'd0), .rx_n(5'd0),
        .rx_hex(1'b0), .role_kb(role_kb), .blink(1'b0), .note(2'd0),
        .link_ok(1'b0), .link_fail(1'b0), .cur_x(cur_x), .cur_y(cur_y),
        .oink(1'b0), .has_ink(1'b0), .bxmin(7'd0), .bxmax(7'd0),
        .bymin(6'd0), .bymax(6'd0), .toolbar_valid(toolbar_valid),
        .toolbar_pdata(toolbar_pdata), .pdata(screen_pdata));

    always #5 clk = ~clk;

    task step;
        begin @(posedge clk); #1; end
    endtask

    task release_left;
        begin mouse_left = 0; step; end
    endtask

    task click_mouse;
        input integer x, y;
        begin
            mouse_x = x; mouse_y = y; px = x; py = y; mouse_left = 0; step;
            mouse_left = 1; step;
            mouse_left = 0;
        end
    endtask

    task expect_pulse;
        input [255:0] what;
        input integer got;
        input integer want;
        begin
            if (got != want) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d want %0d", what, got, want);
            end
        end
    endtask

    initial begin
        step; step; rst = 0; step;

        // DRAW: SEND, CLR, MSG
        mouse_x = 10; mouse_y = 55; mouse_left = 1; step;
        expect_pulse("DRAW SEND", click_submit, 1);
        release_left;
        click_mouse(40, 55);
        expect_pulse("DRAW CLR", click_clear, 1);
        click_mouse(75, 55);
        expect_pulse("DRAW MSG", click_next, 1);

        // A canvas press paints, then stops painting in the toolbar.
        state = 0; mouse_x = 50; mouse_y = 30; mouse_left = 0; step;
        mouse_left = 1; step;
        if (!paint_ok) begin errors = errors + 1; $display("FAIL: canvas press did not enable paint"); end
        mouse_y = 55; #1;
        if (paint_ok) begin errors = errors + 1; $display("FAIL: toolbar did not suppress paint"); end
        release_left;

        // WAIT STOP is deliberately the left button, away from the orbit.
        state = 1;
        click_mouse(10, 55);
        expect_pulse("WAIT STOP", click_clear, 1);

        // RESULT: OK, RETRY
        state = 2;
        click_mouse(10, 55);
        expect_pulse("RESULT OK", click_confirm, 1);
        click_mouse(40, 55);
        expect_pulse("RESULT RETRY", click_retry, 1);

        // MSG: SEND, CLR, RX; RX: CLR, BACK.
        state = 3;
        click_mouse(10, 55);
        expect_pulse("MSG SEND", click_confirm, 1);
        click_mouse(40, 55);
        expect_pulse("MSG CLR", click_clear, 1);
        click_mouse(75, 55);
        expect_pulse("MSG RX", click_next, 1);
        state = 4;
        click_mouse(10, 55);
        expect_pulse("RX CLR", click_clear, 1);
        click_mouse(40, 55);
        expect_pulse("RX BACK", click_next, 1);

        // Hover and flash are visible on the selected button.
        state = 0; mouse_left = 0; step;
        mouse_x = 10; mouse_y = 55; px = 10; py = 55; #1;
        if (toolbar_pdata === 16'h0000 || !toolbar_valid) begin
            errors = errors + 1; $display("FAIL: hover button is not visible");
        end
        mouse_left = 1; step;
        if (toolbar_pdata !== 16'hFFFF && toolbar_pdata !== 16'hFFE0) begin
            errors = errors + 1; $display("FAIL: clicked button did not flash");
        end
        release_left;

        // Debug cursor uses button levels and suppresses direct button actions.
        debug_en = 1; mouse_x = 10; mouse_y = 55; step;
        btn_r_level = 1; step; btn_r_level = 0; step;
        if (cur_x != 11) begin errors = errors + 1; $display("FAIL: debug cursor x=%0d want 11", cur_x); end
        btn_c_level = 1; step;
        if (!click_submit) begin errors = errors + 1; $display("FAIL: debug click did not submit"); end
        btn_c_level = 0; step;
        if (left) begin errors = errors + 1; $display("FAIL: debug left remained high"); end

        // A held direction moves once, waits, then repeats slowly.
        debug_en = 0; step;
        debug_en = 1; mouse_x = 10; mouse_y = 30; step;
        btn_r_level = 1;
        for (combined = 0; combined < 12; combined = combined + 1) step;
        if (cur_x <= 10 || cur_x > 13) begin
            errors = errors + 1; $display("FAIL: debug repeat moved to x=%0d", cur_x);
        end
        btn_r_level = 0; step;
        debug_en = 0; step;

        // Empty toolbar slots must neither click nor become valid buttons.
        state = 1; click_mouse(40, 55);
        expect_pulse("WAIT empty slot", click_clear, 0);
        state = 2; click_mouse(75, 55);
        expect_pulse("RESULT empty slot", click_retry, 0);
        state = 4; click_mouse(75, 55);
        expect_pulse("RX empty slot", click_next, 0);

        // Cursor is drawn over, rather than underneath, a toolbar button.
        state = 0; mouse_x = 10; mouse_y = 55; px = 10; py = 55; step;
        if (screen_pdata !== 16'hF800) begin
            errors = errors + 1; $display("FAIL: toolbar cursor pixel = %h", screen_pdata);
        end

        // A merged action is one asserted pulse even when both sources fire.
        state = 2; mouse_left = 0; step;
        mouse_x = 10; mouse_y = 55; push_confirm = 1; mouse_left = 1; step;
        combined = merged_confirm;
        expect_pulse("merged same-cycle action", combined, 1);
        push_confirm = 0; mouse_left = 0; step;

        if (errors == 0) $display("PASS: tb_ui_buttons");
        else             $display("FAIL: tb_ui_buttons, %0d errors", errors);
        $finish;
    end
endmodule