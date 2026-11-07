`timescale 1ns / 1ps

module tb_led_cascade;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg trig_send = 1'b0;
    reg trig_recv = 1'b0;
    reg role = 1'b0;
    wire [15:0] led_cas;
    wire active;
    integer errors = 0;
    integer cycles;

    always #5 clk = ~clk;

    led_cascade #(.DURATION_CYCLES(56), .LED_COUNT(16), .BAR_WIDTH(3)) dut (
        .clk(clk), .rst(rst), .trig_send(trig_send), .trig_recv(trig_recv),
        .role(role), .led_cas(led_cas), .active(active));

    task pulse_send;
        begin
            @(negedge clk); trig_send = 1'b1;
            @(negedge clk); trig_send = 1'b0;
        end
    endtask

    task check_bar;
        input [15:0] expected;
        input [255:0] tag;
        begin
            if (led_cas !== expected) begin
                errors = errors + 1;
                $display("FAIL %0s: led_cas=%h expected=%h", tag, led_cas, expected);
            end
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = 1'b0;

        role = 1'b0;
        pulse_send;
        @(negedge clk); check_bar(16'h0007, "sender start");
        repeat (4) @(negedge clk);
        check_bar(16'h000E, "sender middle");

        pulse_send;
        @(negedge clk);
        if (!active || led_cas === 16'h0007) begin
            errors = errors + 1;
            $display("FAIL retrigger: active=%b led_cas=%h", active, led_cas);
        end
        repeat (60) @(negedge clk);
        if (active) begin
            errors = errors + 1;
            $display("FAIL sender did not finish");
        end

        role = 1'b1;
        trig_recv = 1'b1;
        @(negedge clk); trig_recv = 1'b0;
        @(negedge clk); check_bar(16'hE000, "receiver start");
        repeat (60) @(negedge clk);
        if (active) begin
            errors = errors + 1;
            $display("FAIL receiver did not finish");
        end

        pulse_send;
        @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        if (active || led_cas !== 16'd0) begin
            errors = errors + 1;
            $display("FAIL reset cancel: active=%b led_cas=%h", active, led_cas);
        end

        if (errors == 0) $display("PASS: tb_led_cascade");
        else             $display("FAIL: tb_led_cascade, %0d errors", errors);
        $finish;
    end
endmodule
