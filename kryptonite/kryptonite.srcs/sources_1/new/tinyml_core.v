`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.11.2026 02:53:00
// Design Name: 
// Module Name: tinyml_core
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


module tinyml_core #(
    parameter INPUT_NODES = 64,
    parameter HIDDEN_NODES = 16,
    parameter OUTPUT_NODES = 10
)(
    input clk,
    input clear,
    input start,
    input [INPUT_NODES-1:0] pixels,
    output reg [3:0] prediction = 0,
    output reg done = 0
);
    reg [15:0] hidden_weights [0 : (INPUT_NODES * HIDDEN_NODES) - 1];
    reg [15:0] hidden_biases  [0 : HIDDEN_NODES - 1];
    reg [15:0] output_weights [0 : (HIDDEN_NODES * OUTPUT_NODES) - 1];
    reg [15:0] output_biases  [0 : OUTPUT_NODES - 1];
    
    initial begin
        $readmemh("hw.mem", hidden_weights);
        $readmemh("hb.mem", hidden_biases);
        $readmemh("ow.mem", output_weights);
        $readmemh("ob.mem", output_biases);
    end

    reg [INPUT_NODES-1:0] pixel_buffer;
    always @ (posedge clk) begin
        if (clear) 
            pixel_buffer <= 0;
        else if (start) 
            pixel_buffer <= pixels;
    end
    
    reg [1:0] state = 0;
    reg [15:0] pixel_idx = 0;
    reg [15:0] node_idx = 0;
    reg signed [31:0] accumulator = 0;
    reg signed [15:0] hidden_nodes [0 : HIDDEN_NODES - 1];
    reg signed [31:0] output_scores [0 : OUTPUT_NODES - 1];
    reg signed [31:0] best_score;
    reg [3:0] best_digit;

    always @ (posedge clk) begin
        done <= 1'b0;
        case (state)
            2'b00: begin
                if (start) begin
                    state <= 2'b01;
                    pixel_idx <= 0;
                    node_idx <= 0;
                    accumulator <= 0;
                end
            end
            
            2'b01: begin
                if (node_idx < HIDDEN_NODES) begin
                    if (pixel_idx < INPUT_NODES) begin
                        accumulator <= accumulator + (pixel_buffer[pixel_idx] * hidden_weights[(node_idx * INPUT_NODES) + pixel_idx]);
                        pixel_idx <= pixel_idx + 1;
                    end else begin
                        hidden_nodes[node_idx] <= ((accumulator + $signed(hidden_biases[node_idx])) < 0) ? 16'd0 : (accumulator + $signed(hidden_biases[node_idx]));
                        accumulator <= 0;
                        pixel_idx <= 0;
                        node_idx <= node_idx + 1;
                    end
                end else begin
                    state <= 2'b10;
                    pixel_idx <= 0;
                    node_idx <= 0;
                    accumulator <= 0; 
                end
            end
            2'b10: begin
                if (node_idx < OUTPUT_NODES) begin
                    if (pixel_idx < HIDDEN_NODES) begin
                        accumulator <= accumulator + (hidden_nodes[pixel_idx] * output_weights[(node_idx * HIDDEN_NODES) + pixel_idx]);
                        pixel_idx <= pixel_idx + 1;
                    end else begin
                        output_scores[node_idx] <= accumulator + $signed(output_biases[node_idx]);
                        accumulator <= 0;
                        pixel_idx <= 0;
                        node_idx <= node_idx + 1;
                    end
                end else begin
                    state <= 2'b11;
                    node_idx <= 0;
                end
            end
            2'b11: begin
                if (node_idx < OUTPUT_NODES) begin
                    // Seed from score 0 and keep the lower digit on ties.
                    if (node_idx == 0 || output_scores[node_idx] > best_score) begin
                        best_score <= output_scores[node_idx];
                        best_digit <= node_idx[3:0];
                    end
                    node_idx <= node_idx + 1;
                end else begin
                    // Publish after the final comparison has updated best_digit.
                    prediction <= best_digit;
                    done <= 1'b1;
                    state <= 2'b00;
                end
            end
        endcase
    end
endmodule
