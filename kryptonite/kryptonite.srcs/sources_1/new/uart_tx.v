`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_tx.v  (Khushi)
//
// Sends one byte as a UART frame, "8N1":
//     idle line = 1
//     start bit = 0
//     8 data bits, least significant bit first
//     stop bit  = 1
// Each bit lasts 16 ticks of tick16 (= 1/115200 s = 8.68 us).
//
// Usage: when ready = 1, put the byte on 'data' and pulse 'start' for one
// clock. 'done' pulses for one clock after the stop bit has been sent.
//////////////////////////////////////////////////////////////////////////////
module uart_tx (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick16,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,       // the serial line
    output wire       ready,
    output reg        done
);
    reg        busy;
    reg [9:0]  shift;           // {stop, data[7:0], start}, sent from bit 0
    reg [3:0]  bit_idx;         // 0..9
    reg [3:0]  tick_cnt;        // 0..15 within a bit

    assign ready = ~busy;

    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
            shift <= 10'h3FF;
            bit_idx <= 0;
            tick_cnt <= 0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                tx <= 1'b1;
                if (start) begin
                    shift    <= {1'b1, data, 1'b0};
                    busy     <= 1'b1;
                    bit_idx  <= 0;
                    tick_cnt <= 0;
                end
            end else begin
                tx <= shift[0];
                if (tick16) begin
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= 0;
                        shift    <= {1'b1, shift[9:1]};
                        if (bit_idx == 4'd9) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end else begin
                        tick_cnt <= tick_cnt + 4'd1;
                    end
                end
            end
        end
    end
endmodule
