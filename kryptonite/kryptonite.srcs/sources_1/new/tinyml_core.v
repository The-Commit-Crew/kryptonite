`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tinyml_core.v - 64-input MLP digit classifier (Divyansh; pipelined by Khushi)
//
//   hidden[n] = ReLU( sum_i pixel[i] * hw[n*64 + i] + hb[n] )          n = 0..HIDDEN-1
//   score[o]  =       sum_j hidden[j] * ow[o*HIDDEN + j] + (ob[o] << 8)  o = 0..9
//   prediction = argmax(score), lowest digit wins a tie
//
// Weights are Q8.8 (hw.mem, hb.mem, ow.mem, ob.mem from ml_engine/export_weights.py).
// The arithmetic and the result are exactly the same as the original single-cycle
// version; only the timing changed. The original did a 4096-entry weight lookup,
// a 64:1 pixel select, a multiply and an add in one clock, which cannot run at
// 100 MHz. Now every multiply-accumulate goes through a short pipeline:
//
//   S0  issue: address = {node, index}
//   S1  weight read from block RAM, pixel (or hidden value) selected
//   S2  product registered
//   S3  accumulate; on the last term of a node, add the bias and store the result
//
// One term per clock, so a full inference takes about 64*64 + 10*64 = 4,700 clocks
// (47 us at 100 MHz).
//////////////////////////////////////////////////////////////////////////////////
module tinyml_core #(
    parameter INPUT_NODES = 64,
    parameter HIDDEN_NODES = 64,
    parameter OUTPUT_NODES = 10
)(
    input clk,
    input clear,
    input start,
    input [(INPUT_NODES * 5)-1:0] pixels,
    output reg [3:0] prediction = 0,
    output reg done = 0,
    output wire busy
);
    localparam IW = $clog2(INPUT_NODES);
    localparam HW_ = $clog2(HIDDEN_NODES);
    // A five-bit unsigned pixel times a signed 16-bit weight needs 21 bits.
    localparam HIDDEN_WIDTH = 21 + $clog2(INPUT_NODES + 1);
    localparam SCORE_WIDTH  = HIDDEN_WIDTH + 16 + $clog2(HIDDEN_NODES);

    //------------------------------------------------------------ weights
    (* ram_style = "block" *) reg signed [15:0] hidden_weights [0 : (INPUT_NODES * HIDDEN_NODES) - 1];
    (* ram_style = "block" *) reg signed [15:0] output_weights [0 : (HIDDEN_NODES * OUTPUT_NODES) - 1];
    reg [15:0] hidden_biases [0 : HIDDEN_NODES - 1];
    reg [15:0] output_biases [0 : OUTPUT_NODES - 1];
    initial begin
        $readmemh("hw.mem", hidden_weights);
        $readmemh("hb.mem", hidden_biases);
        $readmemh("ow.mem", output_weights);
        $readmemh("ob.mem", output_biases);
    end

    // hidden layer results (written in S3, read in S1 of layer 2)
    reg signed [HIDDEN_WIDTH-1:0] hidden_nodes [0 : HIDDEN_NODES - 1];

    //------------------------------------------------------------ control
    localparam IDLE = 3'd0, L1 = 3'd1, L1_DRAIN = 3'd2, L2 = 3'd3, L2_DRAIN = 3'd4, ARG = 3'd5;
    reg [2:0] state = IDLE;
    assign busy = (state != IDLE);

    reg [(INPUT_NODES * 5)-1:0] pixel_buffer;
    reg [HW_:0] node;                   // issue side: node being issued
    reg [HW_:0] idx;                    // issue side: term inside the node
    wire layer2 = (state == L2) || (state == L2_DRAIN);
    wire [HW_:0] terms = layer2 ? HIDDEN_NODES : INPUT_NODES;
    wire [HW_:0] nodes = layer2 ? OUTPUT_NODES : HIDDEN_NODES;
    wire issuing = (state == L1) || (state == L2);

    // S0 -> S1
    reg              v0, last0;
    reg [15:0]       w_addr;
    reg [HW_:0]      i0;
    // S1 -> S2
    reg              v1, last1;
    reg signed [15:0]            wh_q, wo_q;   // one registered read per block RAM
    reg signed [HIDDEN_WIDTH:0]  x_q;   // pixel (0..16) or hidden value, as signed
    // S2 -> S3
    reg              v2, last2;
    reg signed [SCORE_WIDTH-1:0] p_q;
    // S3
    reg signed [SCORE_WIDTH-1:0] accumulator = 0;
    reg [HW_:0]      out_node;          // which node S3 is finishing

    reg signed [SCORE_WIDTH-1:0] output_scores [0 : OUTPUT_NODES - 1];
    reg signed [SCORE_WIDTH-1:0] best_score;
    reg [3:0] best_digit;
    reg [HW_:0] arg_i;

    wire signed [SCORE_WIDTH-1:0] sum_now = accumulator + p_q;
    wire signed [SCORE_WIDTH-1:0] hidden_total = sum_now + $signed(hidden_biases[out_node]);
    wire signed [SCORE_WIDTH-1:0] score_total  = sum_now + ($signed(output_biases[out_node]) <<< 8);
    wire pipe_empty = !v0 && !v1 && !v2;

    always @(posedge clk) begin
        done <= 1'b0;
        if (clear) begin
            state <= IDLE; v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0;
            accumulator <= 0; node <= 0; idx <= 0; out_node <= 0;
        end else begin
            //---------------- S0: issue one term per clock
            v0 <= issuing;
            if (issuing) begin
                w_addr <= layer2 ? (node * HIDDEN_NODES + idx) : (node * INPUT_NODES + idx);
                i0     <= idx;
                last0  <= (idx == terms - 1);
                if (idx == terms - 1) begin
                    idx <= 0;
                    if (node == nodes - 1) state <= layer2 ? L2_DRAIN : L1_DRAIN;
                    node <= node + 1'b1;
                end else idx <= idx + 1'b1;
            end

            //---------------- S1: weight from block RAM, input selected
            v1 <= v0; last1 <= last0;
            wh_q <= hidden_weights[w_addr];
            wo_q <= output_weights[w_addr[HW_+3:0]];
            x_q <= layer2 ? {1'b0, hidden_nodes[i0[HW_-1:0]]}
                          : $signed({{(HIDDEN_WIDTH-4){1'b0}}, pixel_buffer[i0[IW-1:0]*5 +: 5]});

            //---------------- S2: multiply
            v2 <= v1; last2 <= last1;
            p_q <= x_q * (layer2 ? wo_q : wh_q);

            //---------------- S3: accumulate / finish a node
            if (v2) begin
                if (last2) begin
                    if (!layer2)
                        hidden_nodes[out_node[HW_-1:0]] <= (hidden_total < 0) ?
                            {HIDDEN_WIDTH{1'b0}} : hidden_total[HIDDEN_WIDTH-1:0];
                    else
                        output_scores[out_node] <= score_total;
                    accumulator <= 0;
                    out_node <= out_node + 1'b1;
                end else accumulator <= sum_now;
            end

            //---------------- sequencing
            case (state)
                IDLE: if (start) begin
                    pixel_buffer <= pixels;
                    node <= 0; idx <= 0; out_node <= 0; accumulator <= 0;
                    state <= L1;
                end
                L1_DRAIN: if (pipe_empty) begin          // all hidden values stored
                    node <= 0; idx <= 0; out_node <= 0;
                    state <= L2;
                end
                L2_DRAIN: if (pipe_empty) begin          // all scores stored
                    arg_i <= 0;
                    state <= ARG;
                end
                ARG: begin
                    if (arg_i < OUTPUT_NODES) begin
                        if (arg_i == 0 || output_scores[arg_i] > best_score) begin
                            best_score <= output_scores[arg_i];
                            best_digit <= arg_i[3:0];
                        end
                        arg_i <= arg_i + 1'b1;
                    end else begin
                        prediction <= best_digit;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
