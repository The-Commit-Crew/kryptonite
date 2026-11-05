`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 23:32:04
// Design Name: 
// Module Name: basemul_core
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


module basemul_core #(
    parameter N = 256,
    parameter COEFF_W = 12,
    parameter ADDR_W = 8,
    parameter Q = 3329
)( input clk, rst, go, output done );
    reg [COEFF_W-1:0] s0_hat [0:N-1];
    reg [COEFF_W-1:0] s1_hat [0:N-1];
    reg [COEFF_W-1:0] u0_hat [0:N-1];
    reg [COEFF_W-1:0] u1_hat [0:N-1];
    reg [COEFF_W-1:0] gammas [0:N/2-1];
    reg [COEFF_W-1:0] prod [0:N-1];
    
    initial begin
        $readmemh("s0_hat.mem", s0_hat);
        $readmemh("s1_hat.mem", s1_hat);
        $readmemh("u0_hat.mem", u0_hat);
        $readmemh("u1_hat.mem", u1_hat);
        $readmemh("gammas.mem", gammas);
    end
    reg [ADDR_W-2:0] i;
    reg p;
    wire [ADDR_W-1:0] addr0 = {i, 1'b0};
    wire [ADDR_W-1:0] addr1 = {i, 1'b1};
    
    reg [COEFF_W-1:0] s0a_q, s0b_q, s1a_q, s1b_q, u0a_q, u0b_q, u1a_q, u1b_q, gamma_q;
    always @(posedge clk) begin
        s0a_q <= s0_hat[addr0];
        s0b_q <= s0_hat[addr1];
        s1a_q <= s1_hat[addr0];
        s1b_q <= s1_hat[addr1];
        u0a_q <= u0_hat[addr0];
        u0b_q <= u0_hat[addr1];
        u1a_q <= u1_hat[addr0];
        u1b_q <= u1_hat[addr1];
        gamma_q <= gammas[i];
    end
    wire [COEFF_W-1:0] m00_r, m01_r, m10_r, m11_r, mg_r;
    reg [COEFF_W-1:0] r00, r01, r10, r11, r11g, c0, c1;
    wire [COEFF_W-1:0] a0 = p?s1a_q:s0a_q;
    wire [COEFF_W-1:0] a1 = p?s1b_q:s0b_q;
    wire [COEFF_W-1:0] b0 = p?u1a_q:u0a_q;
    wire [COEFF_W-1:0] b1 = p?u1b_q:u0b_q;
    wire [23:0] m00 = a0 * b0;
    wire [23:0] m11 = a1 * b1;
    wire [23:0] m10 = a1 * b0;
    wire [23:0] m01 = a0 * b1;
    wire [23:0] mg = r11 * gamma_q;

    barrett_reduce red00(.x(m00),.r(m00_r));
    barrett_reduce red01(.x(m01),.r(m01_r));
    barrett_reduce red10(.x(m10),.r(m10_r));
    barrett_reduce red11(.x(m11),.r(m11_r));
    barrett_reduce redg(.x(mg),.r(mg_r));
    
    wire [COEFF_W:0] c0_t1 = c0 + r00;
    wire [COEFF_W-1:0] c0_s1 = (c0_t1 >= Q)? c0_t1 - Q : c0_t1;
    wire [COEFF_W:0] c0_t2 = c0_s1 + r11g;
    wire [COEFF_W-1:0] c0_next = (c0_t2 >= Q)? c0_t2 - Q : c0_t2;
    
    wire [COEFF_W:0] c1_t1 = c1 + r01;
    wire [COEFF_W-1:0] c1_s1 = (c1_t1 >= Q)? c1_t1 - Q : c1_t1;
    wire [COEFF_W:0] c1_t2 = c1_s1 + r10;
    wire [COEFF_W-1:0] c1_next = (c1_t2 >= Q)? c1_t2 - Q : c1_t2;
    
    localparam IDLE = 4'd0, INIT = 4'd1, READ = 4'd2, MUL = 4'd3, GAMMA = 4'd4, ACC = 4'd5, WRITE0 = 4'd6, WRITE1 = 4'd7, DONE = 4'd8;
    reg [3:0] state = IDLE;
    assign done = (state == DONE);
    
    always @ (posedge clk) begin
        if(rst) begin
            state <= IDLE;
        end else
        case(state)
            IDLE: begin
                if(go) begin
                    i <= 0;
                    state <= INIT;
                end
            end
            INIT: begin
                c0 <= 0;
                c1 <= 0;
                p <= 0;
                state <= READ;
            end
            READ: state <= MUL;
            MUL: begin
                r00 <= m00_r;
                r01 <= m01_r;
                r10 <= m10_r;
                r11 <= m11_r;
                state <= GAMMA;
            end
            GAMMA: begin
                r11g <= mg_r;
                state <= ACC;
            end
            ACC: begin
                c0 <= c0_next;
                c1 <= c1_next;
                if (p == 0) begin
                    p <= 1;
                    state <= READ;
                end else state <= WRITE0;
            end
            WRITE0: state <= WRITE1;
            WRITE1: if(i == N/2 - 1) state <= DONE;
            else begin
                i <= i+1;
                state <= INIT;
            end
            DONE: begin
                if(go) begin
                    i <= 0;
                    state <= INIT;
                end
            end
            default: state <= IDLE;
        endcase
    end
    
    wire we_en = (state == WRITE0) || (state == WRITE1);
    wire [ADDR_W-1:0] w_addr = (state == WRITE1)? addr1: addr0;
    wire [COEFF_W-1:0] w_data = (state == WRITE1)? c1:c0;
    always @(posedge clk) begin
        if(we_en) prod[w_addr] <= w_data;
    end

endmodule
