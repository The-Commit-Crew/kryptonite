`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/04/2026 06:16:47 PM
// Design Name: 
// Module Name: ui_ctrl
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

module ui_ctrl #(
    parameter MAXLEN   = 16,
    parameter WAIT_TMO = 24'd16_000_000      // ~160 ms at 100 MHz
)(
    input clk,
    input rst,
    input p_submit, p_confirm, p_retry, p_clear, p_next,   // 1-clock pulses
    input busy_i,                       // pipeline busy: ignore submit
    input pred_valid,                   // 1-clock pulse: prediction ready
    input [3:0] pred,
    input empty_i,                      // 1-clock pulse: canvas was empty
    input skip_rx,                      // 1: MSG -> DRAW on next (sender board has no RX screen)
    output reg  [2:0] state = 3'd0,
    output reg  [3:0] digit = 4'd0,           // digit shown on the RESULT screen
    output reg  [MAXLEN*4-1:0] msg = 0,       // confirmed digits, digit 0 in [3:0]
    output reg  [4:0] msg_len = 5'd0,
    output reg  [1:0] note = 2'd0,            // 0 none, 1 EMPTY, 2 ERR
    output reg  submit_out = 1'b0,            // pulse to the vision pipeline
    output reg  clear_out  = 1'b0,            // pulse: clear the canvas
    output reg  confirm_out = 1'b0,           // pulse: a digit was just confirmed (digit holds it)
    output reg  rx_clear_out = 1'b0           // pulse: clear the received log
);
    localparam S_DRAW = 3'd0, S_WAIT = 3'd1, S_RESULT = 3'd2, S_MSG = 3'd3, S_RX = 3'd4;

    reg [23:0] tmo = 24'd0;

    always @(posedge clk) begin
        submit_out   <= 1'b0;
        clear_out    <= 1'b0;
        confirm_out  <= 1'b0;
        rx_clear_out <= 1'b0;
        if (rst) begin
            state   <= S_DRAW;
            digit   <= 4'd0;
            msg     <= 0;
            msg_len <= 5'd0;
            note    <= 2'd0;
            tmo     <= 24'd0;
        end else begin
            case (state)
                S_DRAW: begin
                    if (p_clear) begin
                        clear_out <= 1'b1;
                        note      <= 2'd0;
                    end else if (p_submit && !busy_i) begin
                        submit_out <= 1'b1;
                        note       <= 2'd0;
                        tmo        <= 24'd0;
                        state      <= S_WAIT;
                    end else if (p_next) begin
                        state <= S_MSG;
                    end
                end

                S_WAIT: begin
                    tmo <= tmo + 24'd1;
                    if (p_clear || p_retry) begin
                        clear_out <= 1'b1;
                        state     <= S_DRAW;
                    end else if (pred_valid) begin
                        digit <= pred;
                        state <= S_RESULT;
                    end else if (empty_i) begin
                        note  <= 2'd1;
                        state <= S_DRAW;
                    end else if (tmo == WAIT_TMO) begin
                        note  <= 2'd2;
                        state <= S_DRAW;
                    end
                end

                S_RESULT: begin
                    if (p_confirm && msg_len < MAXLEN) begin
                        msg[msg_len*4 +: 4] <= digit;
                        msg_len     <= msg_len + 5'd1;
                        confirm_out <= 1'b1;          // tells ui_link to send 'digit'
                        clear_out   <= 1'b1;
                        state       <= S_DRAW;
                    end else if (p_retry || p_clear) begin
                        clear_out <= 1'b1;
                        state     <= S_DRAW;
                    end
                end

                S_MSG: begin
                    if (p_next) begin
                        state <= skip_rx ? S_DRAW : S_RX;
                    end else if (p_clear) begin
                        msg     <= 0;
                        msg_len <= 5'd0;
                    end
                end

                S_RX: begin
                    if (p_next) begin
                        state <= S_DRAW;
                    end else if (p_clear) begin
                        rx_clear_out <= 1'b1;
                    end
                end

                default: state <= S_DRAW;
            endcase
        end
    end
endmodule
