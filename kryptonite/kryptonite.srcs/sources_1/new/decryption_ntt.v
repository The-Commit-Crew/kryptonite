`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06.11.2026 15:50:10
// Design Name: 
// Module Name: decryption_ntt
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


module decryption_ntt#(
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
    reg [COEFF_W-1:0] u0 [0:N-1];
    reg [COEFF_W-1:0] u1 [0:N-1];
    reg [COEFF_W-1:0] v [0:N-1];
    initial begin
        $readmemh("u0.mem", u0);
        $readmemh("u1.mem", u1);
        $readmemh("v.mem", v);
    end
    
    localparam IDLE      = 5'd0,
           LD0_RD    = 5'd1,
           LD0_WR    = 5'd2,
           NTT0_GO   = 5'd3,
           NTT0_WAIT = 5'd4,
           CP0_RD    = 5'd5,
           CP0_WR    = 5'd6,
           LD1_RD    = 5'd7,
           LD1_WR    = 5'd8,
           NTT1_GO   = 5'd9,
           NTT1_WAIT = 5'd10,
           CP1_RD    = 5'd11,
           CP1_WR    = 5'd12,
           BM_GO     = 5'd13,
           BM_WAIT   = 5'd14,
           CPP_RD    = 5'd15,
           CPP_WR    = 5'd16,
           INTT_GO   = 5'd17,
           INTT_WAIT = 5'd18,
           FIN_RD    = 5'd19,
           FIN_CALC  = 5'd20,
           DONE      = 5'd21;

    reg [4:0] state = IDLE;
    assign done = (state == DONE);
        
    reg [ADDR_W-1:0] k;
    reg [COEFF_W-1:0] u0_q, u1_q, v_q;
    always @ (posedge clk) begin
        u0_q <= u0[k];
        u1_q <= u1[k];
        v_q <= v[k];
    end

    wire ntt_go = (state == NTT0_GO) || (state == NTT1_GO);
    wire ntt_we = (state == LD0_WR) || (state == LD1_WR);
    wire [COEFF_W-1:0] ntt_wdata = (state == LD1_WR) ? u1_q : u0_q;
    wire [COEFF_W-1:0] ntt_rdata;
    wire ntt_done;

    wire bm_go = (state == BM_GO);
    wire bm_we = (state == CP0_WR) || (state == CP1_WR);
    wire bm_sel = (state == CP1_WR);
    wire [COEFF_W-1:0] bm_rdata;
    wire bm_done;

    wire intt_go = (state == INTT_GO);
    wire intt_we = (state == CPP_WR);
    wire [COEFF_W-1:0] intt_rdata;
    wire intt_done;
    
    ntt_core u_ntt (
    .clk(clk), .rst(rst), .go(ntt_go), .done(ntt_done),
    .ext_we(ntt_we), .ext_addr(k), .ext_wdata(ntt_wdata), .ext_rdata(ntt_rdata)
    );

    basemul_core u_bm (
    .clk(clk), .rst(rst), .go(bm_go), .done(bm_done),
    .ext_we(bm_we), .ext_sel(bm_sel), .ext_addr(k),
    .ext_wdata(ntt_rdata),
    .ext_rdata(bm_rdata)
    );

    intt_core u_intt (
    .clk(clk), .rst(rst), .go(intt_go), .done(intt_done),
    .ext_we(intt_we), .ext_addr(k),
    .ext_wdata(bm_rdata), .ext_rdata(intt_rdata)
    );
    
    wire [COEFF_W:0] w_tmp = v_q + Q - intt_rdata;
    wire [COEFF_W-1:0] w = (w_tmp >= Q)? w_tmp - Q : w_tmp;
    
    always @(posedge clk) begin
        if(rst) begin
        state <= IDLE;
        msg_bits <= 0;
        end
        else begin
            case(state)
                IDLE: if (start) begin
                    k <= 0;
                    state <= LD0_RD;
                end
                LD0_RD: state <= LD0_WR;
                LD0_WR: if (k == 255) begin
                    k <= 0;
                    state <= NTT0_GO;
                end else begin
                    k <= k+1;
                    state <= LD0_RD;
                end
                NTT0_GO: state <= NTT0_WAIT;
                NTT0_WAIT: if (ntt_done) state <= CP0_RD;
                CP0_RD: state <= CP0_WR;
                CP0_WR: if (k == 255) begin
                    k <= 0;
                    state <= LD1_RD;
                end else begin
                    k <= k+1;
                    state <= CP0_RD;
                end
                LD1_RD: state <= LD1_WR;
                LD1_WR: if (k == 255) begin
                    k <= 0;
                    state <= NTT1_GO;
                end else begin
                    k <= k+1;
                    state <= LD1_RD;
                end
                NTT1_GO: state <= NTT1_WAIT;
                NTT1_WAIT: if (ntt_done) state <= CP1_RD;
                CP1_RD: state <= CP1_WR;
                CP1_WR: if (k == 255) begin
                    k <= 0;
                    state <= BM_GO;
                end else begin
                    k <= k+1;
                    state <= CP1_RD;
                end
                BM_GO: state <= BM_WAIT;
                BM_WAIT: if (bm_done) state <= CPP_RD;
                CPP_RD: state <= CPP_WR;
                CPP_WR: if (k == 255) begin
                    k <= 0;
                    state <= INTT_GO;
                end else begin
                    k <= k+1;
                    state <= CPP_RD;
                end
                INTT_GO: state <= INTT_WAIT;
                INTT_WAIT: if(intt_done) state <= FIN_RD;
                FIN_RD: state <= FIN_CALC;
                FIN_CALC: begin
                    msg_bits[k] <= (w >= 833 && w <= 2496);
                    if (k == 255) begin
                        state <= DONE;
                    end else begin
                        k <= k+1;
                        state <= FIN_RD;
                    end
                 end
                 DONE: if (start) begin
                    k <= 0;
                    state <= LD0_RD;
                 end
                 default: state <= IDLE;
            endcase
        end
    end

    
endmodule
