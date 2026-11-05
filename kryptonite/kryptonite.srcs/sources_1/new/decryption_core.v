`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.11.2026 17:28:35
// Design Name: 
// Module Name: decryption_core
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


module decryption_core #(
    parameter N = 256,
    parameter ADDR_W = 8,
    parameter COEFF_W = 12,
    parameter Q = 3329
) (
    input clk,
    input rst,
    input start,
    output done,
    output reg [N-1:0] msg_bits = 0
    );
    reg [COEFF_W-1:0] s0 [0:N-1];
    reg [COEFF_W-1:0] s1 [0:N-1];
    reg [COEFF_W-1:0] u0 [0:N-1];
    reg [COEFF_W-1:0] u1 [0:N-1];
    reg [COEFF_W-1:0] v [0:N-1];
    initial begin
        $readmemh("s0.mem", s0);
        $readmemh("s1.mem", s1);
        $readmemh("u0.mem", u0);
        $readmemh("u1.mem", u1);
        $readmemh("v.mem", v);
    end
    localparam IDLE = 4'd0, INIT_K = 4'd1, ADDR = 4'd2, READ = 4'd3, MUL = 4'd4, RED = 4'd5, ACC = 4'd6, FINAL_READ = 4'd7, FINAL = 4'd8, DONE = 4'd9;
    reg [3:0] state = IDLE;
    assign done = (state == DONE);
    
    reg [ADDR_W-1:0] k, i; reg p;
    wire [ADDR_W-1:0] j = k - i;
    reg [COEFF_W-1:0] acc, red;
    reg [23:0] prod;
    wire [COEFF_W-1:0] barrett_out;
    barrett_reduce reduce(.x(prod), .r(barrett_out));
    
    reg [COEFF_W-1:0] s0_q, s1_q, u0_q, u1_q, v_q;
    always @ (posedge clk) begin
        s0_q <= s0[i];
        s1_q <= s1[i];
        u0_q <= u0[j];
        u1_q <= u1[j];
        v_q <= v[k];
    end
    
    wire [COEFF_W-1:0] s_data = p? s1_q:s0_q;
    wire [COEFF_W-1:0] u_data = p? u1_q:u0_q;
    
    wire [12:0] add_tmp = acc + red;
    wire [12:0] sub_tmp = acc + Q - red;
    wire [12:0] chosen = (i <= k)? add_tmp : sub_tmp;
    wire [12:0] w_tmp = v_q + Q - acc;
    wire [12:0] w = (w_tmp >= Q)? w_tmp-Q: w_tmp;
    
    always @ (posedge clk) begin
        if(rst) begin
            state <= IDLE;
            msg_bits <= 0;
            k <= 0;
            i <= 0;
            p <= 0;
            acc <= 0;
        end else begin
            case(state)
                IDLE: begin 
                    state <= start? INIT_K:IDLE;
                    k <= 0;
                end
                INIT_K: begin
                    acc <= 0;
                    i <= 0;
                    p <= 0;
                    state <= ADDR;
                 end
                 ADDR: state <= READ;
                 READ: state <= MUL;
                 MUL: begin
                    prod <= s_data * u_data;
                    state <= RED;
                 end
                 RED: begin
                    red <= barrett_out;
                    state <= ACC;
                 end
                 ACC: begin
                    acc <= (chosen >= Q)? chosen - Q : chosen;
                    if (i < 255) begin
                        i <= i + 1;
                        state <= ADDR;
                    end
                    else if (i == 255 && p == 0) begin
                        p <= 1;
                        i <= 0;
                        state <= ADDR;
                    end
                    else begin
                        state <= FINAL_READ;
                    end
                 end
                 FINAL_READ: state <= FINAL;
                 FINAL: begin
                    msg_bits[k] <= (w >= 833 && w <= 2496);
                    if (k == 255) begin
                        state <= DONE;
                    end else begin
                        k <= k+1;
                        state <= INIT_K;
                    end
                 end
                 DONE: if (start) begin
                    k <= 0;
                    state <= INIT_K;
                 end
                 default: state <= IDLE;
            endcase
        end
    end
    
endmodule
