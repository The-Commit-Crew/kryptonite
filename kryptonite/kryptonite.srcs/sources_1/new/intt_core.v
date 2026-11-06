`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.11.2026 22:15:06
// Design Name: 
// Module Name: intt_core
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


module intt_core#(
    parameter N = 256,
    parameter COEFF_W = 12,
    parameter ADDR_W = 8,
    parameter Q = 3329,
    parameter INIT_FILE = "",
    parameter ZETAS_FILE = "zetas.mem",
    parameter PIPELINED = 0
) ( input clk, rst, go, ext_we,
 input [ADDR_W-1:0] ext_addr,
 input [COEFF_W-1:0] ext_wdata,
 output [COEFF_W-1:0] ext_rdata,
 output done );
    
    reg [COEFF_W - 1:0] f [0:N-1];
    reg [COEFF_W - 1:0] zetas [0:N/2-1];
    
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, f);
        $readmemh(ZETAS_FILE, zetas);
    end
    
    localparam IDLE = 4'd0, READ = 4'd1, CALC = 4'd2, WRITE_A = 4'd3, WRITE_B = 4'd4, SCALE_READ = 4'd5, SCALE_CALC = 4'd6, SCALE_WRITE = 4'd7, DONE = 4'd8,
               PIPE_WAIT = 4'd9, SCALE_PIPE_WAIT = 4'd10;
    reg [3:0] state = IDLE;
    reg [2:0] pipeline_left;
    reg [COEFF_W-1:0] a_new, b_new;
    assign done = (state == DONE);
    wire busy = (state != IDLE) && (state != DONE);
    
    reg [ADDR_W-1:0] len, start, j;
    reg [ADDR_W-2:0] zk = 0;
    
    wire [ADDR_W-1:0] addr_a = j;
    wire [ADDR_W-1:0] addr_b = j+len;
    wire [ADDR_W-1:0] block_last = start + len - 1;
    wire [ADDR_W:0] next_start = start + (2*len);
     wire [ADDR_W-1:0] rd_a = busy? addr_a:ext_addr;
    
    reg [COEFF_W - 1:0] fa_q, fb_q, zeta_q;
    
    always @(posedge clk) begin
        fa_q <= f[rd_a];
        fb_q <= f[addr_b];
        zeta_q <= zetas[zk];
    end

    assign ext_rdata = fa_q;
    

    
    wire we_en = (state == WRITE_A) || (state == WRITE_B) || (state == SCALE_WRITE);
    wire [ADDR_W-1:0] w_addr = (state == WRITE_B) ? addr_b : addr_a;
    wire [COEFF_W-1:0] w_data = (state == WRITE_B)? b_new : a_new;
    wire we_m = busy? we_en : ext_we;
    wire [ADDR_W-1:0] waddr_m = busy? w_addr:ext_addr;
    wire [COEFF_W-1:0] wdata_m = busy? w_data: ext_wdata;
    
    wire [COEFF_W-1:0] bf_a, bf_b;
    wire [11:0] scale_out;
    generate if (PIPELINED) begin : pipelined_butterfly
        wire [12:0] sum = {1'b0, fa_q} + {1'b0, fb_q};
        wire [12:0] difference = {1'b0, fb_q} + 13'd3329 - {1'b0, fa_q};
        wire [11:0] reduced_difference = (difference >= 13'd3329)
                                             ? difference - 13'd3329 : difference;
        assign bf_a = (sum >= 13'd3329) ? sum - 13'd3329 : sum;
        mod_mult_pipeline mul(.clk(clk), .a(reduced_difference), .b(zeta_q), .r(bf_b));
        mod_mult_pipeline scale(.clk(clk), .a(fa_q), .b(12'd3303), .r(scale_out));
    end else begin : combinational_butterfly
        butterfly_inv mul(.a(fa_q), .b(fb_q), .zeta(zeta_q), .a_out(bf_a), .b_out(bf_b));
        wire [23:0] scale_prod = fa_q * 12'd3303;
        barrett_reduce red(.x(scale_prod), .r(scale_out));
    end endgenerate
    
    always @(posedge clk) begin
        if (we_m) begin
            f[waddr_m] <= wdata_m;
        end
    end
    
    always @ (posedge clk) begin
        if(rst) begin
            state <= IDLE;
        end else begin
        case(state)
            IDLE: if(go) begin
                len <= 2;
                start <= 0;
                j <= 0;
                zk <= N/2 - 1;
                state <= READ;
            end
            READ: begin
                pipeline_left <= 5;
                state <= PIPELINED ? PIPE_WAIT : CALC;
            end
            PIPE_WAIT: if (pipeline_left == 1) state <= CALC;
                       else pipeline_left <= pipeline_left - 1'b1;
            CALC: begin
               a_new <= bf_a;
               b_new <= bf_b;
               state <= WRITE_A; 
            end
            WRITE_A: state <= WRITE_B;
            WRITE_B: begin
                if (j != block_last) begin
                    j <= j+1;
                    state <= READ;
                end
                else if (next_start < N) begin
                    start <= next_start;
                    j <= next_start;
                    zk <= zk - 1;
                    state <= READ;
                end
                else if (len != N/2) begin
                    len <= len << 1;
                    start <= 0;
                    j <= 0;
                    zk <= zk - 1;
                    state <= READ;
                end
                else begin
                    j <= 0;
                    state <= SCALE_READ;
                end
            end
            SCALE_READ: begin
                pipeline_left <= 5;
                state <= PIPELINED ? SCALE_PIPE_WAIT : SCALE_CALC;
            end
            SCALE_PIPE_WAIT: if (pipeline_left == 1) state <= SCALE_CALC;
                             else pipeline_left <= pipeline_left - 1'b1;
            SCALE_CALC: begin
                a_new <= scale_out;
                state <= SCALE_WRITE;
            end
            SCALE_WRITE: begin
                if (j == N-1) state <= DONE;
                else begin
                    state <= SCALE_READ;
                    j <= j+1;
                end
            end
            DONE: 
            if(go) begin
                len <= 2;
                start <= 0;
                j <= 0;
                zk <= N/2 - 1;
                state <= READ;
            end
            default: state <= IDLE;
        endcase
        end
    end
    
endmodule
