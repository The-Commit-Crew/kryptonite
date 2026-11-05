`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 06:40:01 PM
// Design Name: 
// Module Name: tb_ui_ctrl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module tb_ui_ctrl;
    reg clk = 0, rst = 1;
    reg p_submit = 0, p_confirm = 0, p_retry = 0, p_clear = 0, p_next = 0;
    reg busy_i = 0, pred_valid = 0, empty_i = 0;
    reg [3:0] pred = 0;
    wire [2:0]  state;
    wire [3:0]  digit;
    wire [15:0] msg;
    wire [4:0]  msg_len;
    wire [1:0]  note;
    wire        submit_out, clear_out, confirm_out, rx_clear_out;
    integer errors = 0, n_sub = 0, n_clr = 0, n_conf = 0, n_rxc = 0, n_c;

    ui_ctrl #(.MAXLEN(4), .WAIT_TMO(24'd20)) dut (
        .clk(clk), .rst(rst),
        .p_submit(p_submit), .p_confirm(p_confirm), .p_retry(p_retry),
        .p_clear(p_clear), .p_next(p_next),
        .busy_i(busy_i), .pred_valid(pred_valid), .pred(pred), .empty_i(empty_i),
        .state(state), .digit(digit), .msg(msg), .msg_len(msg_len), .note(note),
        .submit_out(submit_out), .clear_out(clear_out),
        .confirm_out(confirm_out), .rx_clear_out(rx_clear_out));

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (submit_out)   n_sub  <= n_sub + 1;
        if (clear_out)    n_clr  <= n_clr + 1;
        if (confirm_out)  n_conf <= n_conf + 1;
        if (rx_clear_out) n_rxc  <= n_rxc + 1;
    end

    task step; begin @(posedge clk); #1; end endtask

    // 0 submit, 1 confirm, 2 retry, 3 clear, 4 next  (one clock each)
    task press; input [2:0] which;
        begin
            case (which)
                0: p_submit = 1;  1: p_confirm = 1;  2: p_retry = 1;
                3: p_clear = 1;   4: p_next = 1;
            endcase
            step;
            {p_submit, p_confirm, p_retry, p_clear, p_next} = 5'b0;
            step;
        end
    endtask

    task pred_pulse; input [3:0] d;
        begin pred = d; pred_valid = 1; step; pred_valid = 0; step; end
    endtask

    task expect; input [255:0] what; input integer got; input integer want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL %s: got %0d want %0d", what, got, want);
            end
        end
    endtask

    integer k;
    initial begin
        step; step; step; rst = 0; step;
        expect("start state", state, 0);
        expect("start len",   msg_len, 0);

        press(0);                                  // submit
        expect("submit -> WAIT", state, 1);
        expect("submit pulses",  n_sub, 1);
        pred_pulse(7);
        expect("pred -> RESULT", state, 2);
        expect("digit",          digit, 7);
        press(1);                                  // confirm
        expect("confirm -> DRAW", state, 0);
        expect("len after confirm", msg_len, 1);
        expect("first digit", msg[3:0], 7);
        expect("canvas cleared", n_clr, 1);
        expect("confirm pulse", n_conf, 1);

        press(0);                                  // empty canvas
        empty_i = 1; step; empty_i = 0; step;
        expect("empty -> DRAW", state, 0);
        expect("empty note",    note, 1);

        press(0);                                  // timeout
        expect("note cleared on submit", note, 0);
        for (k = 0; k < 30; k = k + 1) step;
        expect("timeout -> DRAW", state, 0);
        expect("timeout note",    note, 2);

        for (k = 2; k <= 4; k = k + 1) begin       // fill the buffer
            press(0); pred_pulse(k); press(1);
        end
        expect("len full", msg_len, 4);
        expect("msg digits", msg, 16'h4327);
        expect("confirm pulses so far", n_conf, 4);

        press(0); pred_pulse(9);                   // buffer full: confirm ignored
        press(1);
        expect("full: stay RESULT", state, 2);
        expect("full: len same",    msg_len, 4);
        expect("full: no confirm pulse", n_conf, 4);
        press(2);                                  // retry
        expect("retry -> DRAW", state, 0);

        press(4);                                  // message screen
        expect("next -> MSG", state, 3);
        press(3);                                  // clear message
        expect("msg cleared len", msg_len, 0);
        expect("msg cleared",     msg, 0);
        expect("MSG clear: no rx clear", n_rxc, 0);
        press(4);                                  // RX screen
        expect("next -> RX", state, 4);
        press(3);                                  // clear received log
        expect("RX clear pulse", n_rxc, 1);
        expect("RX clear stays in RX", state, 4);
        press(4);
        expect("next -> DRAW", state, 0);

        busy_i = 1; press(0); busy_i = 0;          // busy: submit ignored
        expect("busy ignores submit", state, 0);

        press(0);                                  // clear during WAIT
        n_c = n_clr;
        press(3);
        expect("clear in WAIT -> DRAW", state, 0);
        expect("clear pulse", n_clr, n_c + 1);

        if (errors == 0) $display("PASS: ui_ctrl");
        else             $display("FAIL: ui_ctrl, %0d errors", errors);
        $finish;
    end
endmodule