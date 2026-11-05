`timescale 1ns / 1ps

// UI message -> encryption -> acknowledged UART ciphertext. After failure,
// retry_req sends the retained ciphertext, and send_req encrypts a new snapshot.
module board1_message_tx #(
    parameter FIXED_NOISE = 1'b0,
    parameter KEY_DIR = "crypto/keys/board1",
    parameter NOISE_DIR = "crypto/test_vectors/noise"
)(
    input wire clk, rst, send_req, retry_req,
    input wire [127:0] msg_in,           // Up to 16 ASCII bytes, byte 0 in [7:0].
    input wire [4:0] msg_len_in,
    output wire busy,
    output reg send_ok, send_fail,
    output wire tx_wr_en,
    output wire [6:0] tx_wr_addr,
    output wire [7:0] tx_wr_data, tx_len, tx_type,
    output wire tx_send,
    input wire tx_busy, tx_done, tx_fail,
    output wire mul_wr_en,
    output wire [7:0] mul_wr_addr,
    output wire [11:0] mul_left, mul_right,
    output wire mul_start,
    input wire mul_done,
    output wire [7:0] mul_rd_addr,
    input wire [11:0] mul_rd_data
);
    localparam [2:0] IDLE = 0, START_ENCRYPT = 1, ENCRYPTING = 2,
                     START_TX = 3, TRANSMITTING = 4, FAILED = 5;
    reg [2:0] state;
    reg [127:0] snapshot;
    reg [4:0] snapshot_len;
    wire ready, adapter_done, adapter_fail;
    wire [9:0] ciphertext_addr;
    wire [11:0] ciphertext_data;
    wire new_send = send_req && msg_len_in != 0 && !tx_busy;
    wire release_ciphertext = adapter_done || (state == FAILED && new_send);

    assign busy = tx_busy || (state != IDLE && state != FAILED);

    board1_send #(.FIXED_NOISE(FIXED_NOISE), .ASCII_INPUT(1'b1),
                  .KEY_DIR(KEY_DIR), .NOISE_DIR(NOISE_DIR)) encryption (
        .clk(clk), .rst(rst), .send_req(state == START_ENCRYPT),
        .msg_in(snapshot), .msg_len_in(snapshot_len), .busy(),
        .ciphertext_ready(ready), .ciphertext_release(release_ciphertext),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr),
        .mul_left(mul_left), .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
        .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data)
    );

    ciphertext_uart_tx transmitter (
        .clk(clk), .rst(rst), .start(state == START_TX), .busy(),
        .done(adapter_done), .fail(adapter_fail),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .tx_wr_en(tx_wr_en), .tx_wr_addr(tx_wr_addr), .tx_wr_data(tx_wr_data),
        .tx_len(tx_len), .tx_type(tx_type), .tx_send(tx_send),
        .tx_busy(tx_busy), .tx_done(tx_done), .tx_fail(tx_fail)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            send_ok <= 0;
            send_fail <= 0;
        end else begin
            case (state)
                IDLE, FAILED: begin
                    if (new_send) begin
                        snapshot <= msg_in;
                        snapshot_len <= (msg_len_in > 16) ? 5'd16 : msg_len_in;
                        send_ok <= 0;
                        send_fail <= 0;
                        state <= START_ENCRYPT;
                    end else if (state == FAILED && retry_req && !tx_busy) begin
                        send_ok <= 0;
                        send_fail <= 0;
                        state <= START_TX;
                    end
                end
                START_ENCRYPT: state <= ENCRYPTING;
                ENCRYPTING: if (ready) state <= START_TX;
                START_TX: state <= TRANSMITTING;
                TRANSMITTING: begin
                    if (adapter_done) begin
                        send_ok <= 1;
                        send_fail <= 0;
                        state <= IDLE;
                    end else if (adapter_fail) begin
                        send_ok <= 0;
                        send_fail <= 1;
                        state <= FAILED;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
