`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_rx.v  (Khushi)
//
// Receives 8N1 UART frames.
//
// 1. Synchroniser: the incoming wire is not timed by our clock (the other
//    board has its own 100 MHz crystal), so it first passes through two
//    flip-flops. This stops a signal that changes right at our clock edge
//    from causing metastability (a flip-flop stuck between 0 and 1).
//
// 2. 16x oversampling: each bit lasts 16 ticks. When the line falls (start
//    bit), we count ticks and look at the middle of every bit, far from the
//    edges where the value is changing.
//
// 3. Majority vote: in each bit we take 3 samples (ticks 7, 8, 9) and use
//    the value that appears at least twice. One noisy sample can't flip the
//    bit.
//
// 4. Checks: a start bit that is not 0 in the middle was just a glitch, so
//    we go back to waiting. A stop bit that is not 1 is a framing error.
//////////////////////////////////////////////////////////////////////////////
module uart_rx (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick16,
    input  wire       rx,           // the serial line (asynchronous)
    output reg  [7:0] data,
    output reg        valid,        // one-clock pulse: data holds a new byte
    output reg        frame_err     // one-clock pulse: bad stop bit
);
    // two-flip-flop synchroniser, idle = 1
    reg rx_s1, rx_s2;
    always @(posedge clk) begin
        if (rst) begin rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else     begin rx_s1 <= rx;   rx_s2 <= rx_s1; end
    end

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0] state;
    reg [3:0] tick_cnt;
    reg [2:0] bit_idx;
    reg [7:0] shift;
    reg [2:0] samples;

    wire majority = (samples[0] & samples[1]) | (samples[1] & samples[2]) | (samples[0] & samples[2]);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            tick_cnt <= 0; bit_idx <= 0; shift <= 0; samples <= 0;
            data <= 0; valid <= 1'b0; frame_err <= 1'b0;
        end else begin
            valid <= 1'b0;
            frame_err <= 1'b0;
            case (state)
            S_IDLE: begin
                if (!rx_s2) begin               // falling edge = start bit
                    state <= S_START;
                    tick_cnt <= 0;
                end
            end
            default: if (tick16) begin
                if (tick_cnt == 4'd7 || tick_cnt == 4'd8 || tick_cnt == 4'd9)
                    samples <= {samples[1:0], rx_s2};
                if (tick_cnt == 4'd15) begin
                    tick_cnt <= 0;
                    case (state)
                    S_START: begin
                        if (!majority) begin    // real start bit
                            state <= S_DATA;
                            bit_idx <= 0;
                        end else begin
                            state <= S_IDLE;    // glitch
                        end
                    end
                    S_DATA: begin
                        shift <= {majority, shift[7:1]};   // LSB first
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else bit_idx <= bit_idx + 3'd1;
                    end
                    S_STOP: begin
                        if (majority) begin
                            data  <= shift;
                            valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                        state <= S_IDLE;
                    end
                    endcase
                end else begin
                    tick_cnt <= tick_cnt + 4'd1;
                end
            end
            endcase
        end
    end
endmodule
