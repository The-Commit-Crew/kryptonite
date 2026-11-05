`timescale 1ns / 1ps

// Stream u0, u1, v as 1536 little-endian bytes. Start after ciphertext_ready.
// The consumer accepts a byte when byte_valid and byte_ready are both high.
// Keep the source ciphertext until the downstream transmission is complete.
module ciphertext_serializer (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        busy,
    output reg         done,            // Pulses when the final byte is accepted.

    // Matches board1_send's synchronous read port (one-clock latency).
    output reg  [9:0]  ciphertext_addr,
    input  wire [11:0] ciphertext_data,

    output wire [7:0]  byte_data,
    output wire        byte_valid,
    output wire        byte_last,
    input  wire        byte_ready
);
    localparam [2:0] IDLE = 0, READ_WORD = 1, CAPTURE_WORD = 2,
                     LOW_BYTE = 3, HIGH_BYTE = 4;
    reg [2:0] state;
    reg [11:0] coefficient;

    assign busy = (state != IDLE);
    assign byte_valid = (state == LOW_BYTE || state == HIGH_BYTE);
    assign byte_data = (state == HIGH_BYTE) ? {4'b0000, coefficient[11:8]} : coefficient[7:0];
    assign byte_last = (state == HIGH_BYTE && ciphertext_addr == 10'd767);

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            ciphertext_addr <= 0;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    ciphertext_addr <= 0;
                    state <= READ_WORD;
                end
                READ_WORD: state <= CAPTURE_WORD;
                CAPTURE_WORD: begin
                    coefficient <= ciphertext_data;
                    state <= LOW_BYTE;
                end
                LOW_BYTE: if (byte_ready) state <= HIGH_BYTE;
                HIGH_BYTE: if (byte_ready) begin
                    if (ciphertext_addr == 10'd767) begin
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        ciphertext_addr <= ciphertext_addr + 10'd1;
                        state <= READ_WORD;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
