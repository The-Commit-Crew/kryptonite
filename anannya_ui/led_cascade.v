`timescale 1ns / 1ps

module led_cascade #(
    parameter integer DURATION_CYCLES = 150_000_000,
    parameter integer LED_COUNT = 16,
    parameter integer BAR_WIDTH = 3
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        trig_send,
    input  wire        trig_recv,
    input  wire        role,
    output reg  [15:0] led_cas,
    output reg         active
);
    localparam integer POSITIONS = LED_COUNT - BAR_WIDTH + 1;
    localparam integer STEP_CYCLES = (DURATION_CYCLES / POSITIONS) < 1
                                   ? 1 : (DURATION_CYCLES / POSITIONS);
    localparam integer STEP_W = (STEP_CYCLES <= 1) ? 1 : $clog2(STEP_CYCLES);
    localparam integer POS_W = (POSITIONS <= 1) ? 1 : $clog2(POSITIONS);

    reg send_q = 1'b0;
    reg [STEP_W-1:0] step_count = 0;
    reg [POS_W-1:0] position = 0;

    always @* begin
        led_cas = 16'd0;
        if (active) begin
            if (role)
                led_cas = 16'h0007 << (POSITIONS - 1 - position);
            else
                led_cas = 16'h0007 << position;
        end
    end

    always @(posedge clk) begin
        send_q <= trig_send;
        if (rst) begin
            active     <= 1'b0;
            step_count <= 0;
            position   <= 0;
        end else if (!active) begin
            if ((trig_recv || (trig_send && !send_q))) begin
                active     <= 1'b1;
                step_count <= 0;
                position   <= 0;
            end
        end else if (step_count == STEP_CYCLES - 1) begin
            step_count <= 0;
            if (position == POSITIONS - 1) begin
                active <= 1'b0;
            end else begin
                position <= position + 1'b1;
            end
        end else begin
            step_count <= step_count + 1'b1;
        end
    end
endmodule
