`timescale 1ns / 1ps

module board1_send #(
    parameter FIXED_NOISE = 1'b0,
    parameter ASCII_INPUT = 1'b0,
    parameter KEY_DIR = "crypto/keys/board1",
    parameter NOISE_DIR = "crypto/test_vectors/noise"
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        send_req,         // One-cycle UI Send pulse.
    // ASCII_INPUT=1 accepts 16 ASCII bytes. The default accepts 16 digit nibbles.
    input  wire [(ASCII_INPUT ? 128 : 64)-1:0] msg_in,
    input  wire [4:0]  msg_len_in,
    output wire        busy,

    // Read u0, u1, v at addresses 0..767 with one clock of latency. Pulse
    // ciphertext_release after the consumer has finished with all the data.
    output wire        ciphertext_ready,
    input  wire        ciphertext_release,
    input  wire [9:0]  ciphertext_addr,
    output wire [11:0] ciphertext_data,

    // Normal-form polynomial multiplier interface from encrypt_controller.
    output wire        mul_wr_en,
    output wire [7:0]  mul_wr_addr,
    output wire [11:0] mul_left,
    output wire [11:0] mul_right,
    output wire        mul_start,
    input  wire        mul_done,
    output wire [7:0]  mul_rd_addr,
    input  wire [11:0] mul_rd_data
);
    localparam [2:0] IDLE = 0, SAMPLING = 1, START_ENCRYPT = 2,
                     ENCRYPTING = 3, READY = 4;
    reg [2:0] state;
    reg [255:0] message;

    wire accept_send = (state == IDLE) && send_req && (msg_len_in != 0);
    wire sampling_done, encryption_done;
    wire [2:0] key_poly, noise_poly;
    wire [7:0] source_addr;
    wire [11:0] noise_data;
    reg [11:0] key_data;
    reg [11:0] key_rom [0:1535];

    initial begin
        $readmemh({KEY_DIR, "/A00.mem"}, key_rom,    0,  255);
        $readmemh({KEY_DIR, "/A01.mem"}, key_rom,  256,  511);
        $readmemh({KEY_DIR, "/A10.mem"}, key_rom,  512,  767);
        $readmemh({KEY_DIR, "/A11.mem"}, key_rom,  768, 1023);
        $readmemh({KEY_DIR, "/t0.mem"},  key_rom, 1024, 1279);
        $readmemh({KEY_DIR, "/t1.mem"},  key_rom, 1280, 1535);
    end

    always @(posedge clk)
        key_data <= key_rom[{key_poly, source_addr}];

    generate
        if (FIXED_NOISE) begin : fixed_noise
            reg [11:0] noise_rom [0:1279];
            reg [11:0] noise_word;
            initial begin
                $readmemh({NOISE_DIR, "/r0.mem"},   noise_rom,    0,  255);
                $readmemh({NOISE_DIR, "/r1.mem"},   noise_rom,  256,  511);
                $readmemh({NOISE_DIR, "/e1_0.mem"}, noise_rom,  512,  767);
                $readmemh({NOISE_DIR, "/e1_1.mem"}, noise_rom,  768, 1023);
                $readmemh({NOISE_DIR, "/e2.mem"},   noise_rom, 1024, 1279);
            end
            always @(posedge clk)
                noise_word <= noise_rom[{noise_poly, source_addr}];
            assign noise_data = noise_word;
            assign sampling_done = 1'b0;
        end else begin : live_noise
            noise_sampler sampler (
                .clk(clk), .rst(rst), .start(accept_send), .busy(), .done(sampling_done),
                .rd_poly(noise_poly), .rd_addr(source_addr), .rd_data(noise_data)
            );
        end
    endgenerate

    encrypt_controller controller (
        .clk(clk), .rst(rst), .start(state == START_ENCRYPT), .message(message),
        .busy(), .done(encryption_done),
        .key_poly(key_poly), .noise_poly(noise_poly), .source_addr(source_addr),
        .key_data(key_data), .noise_data(noise_data),
        .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr),
        .mul_left(mul_left), .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
        .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data)
    );

    function [255:0] pack_message;
        input [(ASCII_INPUT ? 128 : 64)-1:0] characters;
        input [4:0] length;
        integer i;
        reg [3:0] digit;
        begin
            pack_message = {32{8'h20}};
            for (i = 0; i < 16; i = i + 1) begin
                digit = characters[4*i +: 4];
                if (i < length) begin
                    if (ASCII_INPUT)
                        pack_message[8*i +: 8] = characters[8*i +: 8];
                    else
                        pack_message[8*i +: 8] = (digit <= 9) ? (8'h30 + {4'd0, digit}) : 8'h45;
                end
            end
        end
    endfunction

    assign busy = (state != IDLE);
    assign ciphertext_ready = (state == READY);

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: if (accept_send) begin
                    message <= pack_message(msg_in, msg_len_in);
                    state <= FIXED_NOISE ? START_ENCRYPT : SAMPLING;
                end
                SAMPLING: if (sampling_done) state <= START_ENCRYPT;
                START_ENCRYPT: state <= ENCRYPTING;
                ENCRYPTING: if (encryption_done) state <= READY;
                READY: if (ciphertext_release) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
