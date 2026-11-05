`timescale 1ns / 1ps

// Connects board1_send's read port to the exclusive send interface of uart_link.
// One ciphertext uses 12 packets of 128 bytes. Types 0x10..0x1B identify packets
// 0..11, in u0/u1/v order. uart_link supplies framing, checksums, ACKs and retries.
// Keep ciphertext available while busy and after fail, so start can retry it.
// done means the last packet was ACKed and the ciphertext may be released.
module ciphertext_uart_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,           // Pulse once ciphertext is ready.
    output wire        busy,
    output reg         done,
    output reg         fail,

    output wire [9:0]  ciphertext_addr,
    input  wire [11:0] ciphertext_data,

    output wire        tx_wr_en,
    output wire [6:0]  tx_wr_addr,
    output wire [7:0]  tx_wr_data,
    output wire [7:0]  tx_len,
    output wire [7:0]  tx_type,
    output wire        tx_send,
    input  wire        tx_busy,
    input  wire        tx_done,
    input  wire        tx_fail
);
    localparam [2:0] IDLE = 0, WAIT_IDLE = 1, FILL = 2,
                     SEND_PACKET = 3, WAIT_ACK = 4, ABORT = 5;
    reg [2:0] state;
    reg [3:0] fragment;
    reg [6:0] write_addr;
    wire [7:0] byte_data;
    wire byte_valid, byte_ready;

    ciphertext_serializer serializer (
        .clk(clk), .rst(rst || state == ABORT),
        .start(state == WAIT_IDLE && !tx_busy && fragment == 0), .busy(), .done(),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .byte_data(byte_data), .byte_valid(byte_valid), .byte_last(), .byte_ready(byte_ready)
    );

    assign busy = (state != IDLE);
    assign byte_ready = !rst && (state == FILL) && !tx_busy;
    assign tx_wr_en = byte_valid && byte_ready;
    assign tx_wr_addr = write_addr;
    assign tx_wr_data = byte_data;
    assign tx_len = 8'd128;
    assign tx_type = 8'h10 + {4'b0, fragment};
    assign tx_send = !rst && (state == SEND_PACKET) && !tx_busy;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            fragment <= 0;
            write_addr <= 0;
            done <= 0;
            fail <= 0;
        end else begin
            done <= 0;
            fail <= 0;
            case (state)
                IDLE: if (start) begin
                    fragment <= 0;
                    write_addr <= 0;
                    state <= WAIT_IDLE;
                end
                WAIT_IDLE: if (!tx_busy) state <= FILL;
                FILL: if (tx_wr_en) begin
                    if (write_addr == 7'd127)
                        state <= SEND_PACKET;
                    else
                        write_addr <= write_addr + 7'd1;
                end
                SEND_PACKET: if (!tx_busy) state <= WAIT_ACK;
                WAIT_ACK: begin
                    if (tx_fail) begin
                        state <= ABORT;
                    end else if (tx_done) begin
                        if (fragment == 4'd11) begin
                            done <= 1;
                            state <= IDLE;
                        end else begin
                            fragment <= fragment + 4'd1;
                            write_addr <= 0;
                            state <= WAIT_IDLE;
                        end
                    end
                end
                ABORT: begin
                    fail <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
