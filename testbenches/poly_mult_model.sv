`timescale 1ns / 1ps

// Behavioral reference for simulation. Operands and results are in normal form.
module poly_mult_model (
    input  logic        clk,
    input  logic        rst,
    input  logic        wr_en,
    input  logic [7:0]  wr_addr,
    input  logic [11:0] left_data,
    input  logic [11:0] right_data,
    input  logic        start,
    output logic        done,
    input  logic [7:0]  rd_addr,
    output logic [11:0] rd_data
);
    logic [11:0] left [0:255];
    logic [11:0] right [0:255];
    logic [11:0] result [0:255];
    longint signed accum [0:255];
    longint signed term, residue;
    logic [1:0] remaining;

    always @(posedge clk) begin
        if (rst) begin
            done <= 0;
            remaining <= 0;
        end else begin
            done <= (remaining == 1);
            if (wr_en) begin
                left[wr_addr] <= left_data;
                right[wr_addr] <= right_data;
            end

            if (start) begin
                for (int i = 0; i < 256; i++)
                    accum[i] = 0;
                for (int i = 0; i < 256; i++) begin
                    for (int j = 0; j < 256; j++) begin
                        term = left[i] * right[j];
                        if (i + j < 256)
                            accum[i + j] = accum[i + j] + term;
                        else
                            accum[i + j - 256] = accum[i + j - 256] - term;
                    end
                end
                for (int i = 0; i < 256; i++) begin
                    residue = accum[i] % 64'sd3329;
                    if (residue < 0)
                        residue = residue + 64'sd3329;
                    result[i] <= residue[11:0];
                end
                remaining <= 3;
            end else if (remaining != 0) begin
                remaining <= remaining - 2'd1;
            end
        end
        rd_data <= result[rd_addr];
    end
endmodule
