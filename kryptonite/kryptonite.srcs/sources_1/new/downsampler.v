`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// downsampler.v  (Khushi)
//
// Shrinks the 96x64 drawing into the small grid the classifier reads.
//
// DEFAULT (matches Divyansh's model, trained on scikit-learn's 8x8 digits):
//   GRID = 8, PAD = 0, GREY = 1  ->  64 cells, each a value 0..16
//   scikit-learn made each value by counting the inked pixels in a 4x4 block
//   of a 32x32 drawing (0..16). We do the same thing with our own cell sizes:
//   value = round(count * 16 / area).
//   Its digits fill the frame top to bottom and are centred left to right,
//   with no border, which is exactly what our square-and-centre step gives
//   with PAD = 0.
//
// Other settings:
//   GREY = 0           -> 1 bit per cell (1 if count << TSH >= area)
//   GRID = 16, PAD = 2 -> 16x16 grid with a 2-cell border, MNIST style
//
// Steps, after a one-clock 'start' pulse:
//
//  1. SCAN    Read all 6144 pixels and find the exact bounding box
//             (xmin, xmax, ymin, ymax). Doing a fresh scan here means erased
//             pixels are handled correctly.
//
//  2. SIZE    w = xmax-xmin+1, h = ymax-ymin+1, S = max(w, h).
//             Using a square of side S keeps the aspect ratio, so a tall
//             thin "1" is not stretched into a fat block.
//             Centre the shorter side: x0 = xmin - (S-w)/2, y0 = ymin - (S-h)/2
//
//  3. CELLS   The square is cut into CELLS x CELLS cells (CELLS = GRID - 2*PAD).
//             Cell c covers source pixels from floor(c*S/CELLS)
//             up to floor((c+1)*S/CELLS) - 1. For each cell we COUNT the
//             inked pixels and know its AREA.
//
//  4. VALUE   GREY = 1: value = (count*16 + area/2) / area, done by long
//             division in hardware: 5 compare-and-subtract steps, one per
//             clock, for quotient bits 16, 8, 4, 2, 1. Adding area/2 first
//             makes it round to the nearest whole number instead of down.
//             GREY = 0: 1 if count << TSH >= area (TSH 3 = 12.5%, 2 = 25%).
//
// Division by CELLS without a divider (fixed-point reciprocal):
//      n / 8   =   (n * 32) >> 8          (exact, 8 is a power of two)
//      n / 12  ~=  (n * 683) >> 13        exact for n <= 1152
//      (checked exhaustively in Python)
//
// Output order: cell index = row*GRID + col, row 0 = top, col 0 = left.
//   GREY = 1: cell i is grid[i*5 +: 5]  (5 bits, 0..16)
//   GREY = 0: cell i is grid[i]
// python/preprocess.py (or ml_engine/preprocess.py) does exactly the same
// maths, so test results and training data match the board bit for bit.
//////////////////////////////////////////////////////////////////////////////
module downsampler #(
    parameter GRID  = 8,             // output is GRID x GRID cells
    parameter PAD   = 0,             // empty border cells on each side
    parameter RECIP = 32,            // reciprocal of CELLS, scaled by 2^SHIFT
    parameter SHIFT = 8,             // (32 >> 8 = 1/8 for CELLS = 8)
    parameter GREY  = 1,             // 1: 0..16 per cell, 0: 1 bit per cell
    parameter TSH   = 3              // binary mode only: 3 = 12.5%, 2 = 25%
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,       // one-clock pulse

    // read port into canvas_mem port A (1-cycle read latency)
    output wire [6:0]   rd_x,
    output wire [5:0]   rd_y,
    input  wire         rd_data,

    output wire         busy,
    output reg          done,        // one-clock pulse when grid is ready
    output reg          empty,       // 1 if the canvas had no ink
    output reg  [GRID*GRID*(GREY ? 5 : 1)-1:0] grid,

    // exact bounding box from the last run (handy for debugging / display)
    output reg  [6:0]   xmin,
    output reg  [6:0]   xmax,
    output reg  [5:0]   ymin,
    output reg  [5:0]   ymax
);
    localparam CELLS = GRID - 2 * PAD;   // content cells per side
    localparam VW    = GREY ? 5 : 1;     // bits per cell

    localparam S_IDLE   = 4'd0,
               S_SCAN   = 4'd1,
               S_SFLUSH = 4'd2,
               S_SIZE   = 4'd3,
               S_CA     = 4'd4,      // cell setup: products c*S
               S_CB     = 4'd5,      // cell setup: divide by CELLS
               S_CC     = 4'd6,      // cell setup: add offsets
               S_CD     = 4'd10,     // cell setup: area (own clock, for timing)
               S_READ   = 4'd7,      // read every pixel in the cell
               S_RFLUSH = 4'd8,
               S_DECIDE = 4'd9,
               S_DIVI   = 4'd11,     // greyscale: start long division
               S_DIV    = 4'd12;     // greyscale: one quotient bit per clock

    reg [3:0] state;
    assign busy = (state != S_IDLE);

    //--------------------------------------------------------------- scan
    reg [6:0] sx;
    reg [5:0] sy;
    reg       found;
    reg       tag_valid;             // a counted read is in flight
    reg [6:0] tag_x;
    reg [5:0] tag_y;

    //--------------------------------------------------------------- size
    reg [6:0]        S;              // square side, 1..96
    reg signed [9:0] x0, y0;         // top-left corner of the square

    //--------------------------------------------------------------- cells
    reg [3:0]  cx, cy;               // current cell 0..CELLS-1
    reg [10:0] nxa, nxb, nya, nyb;   // c*S and (c+1)*S
    reg [6:0]  qxa, qxb, qya, qyb;   // those divided by CELLS
    reg signed [9:0] xs, xe, ys, ye; // pixel range of this cell [xs, xe)
    reg signed [9:0] px, py;         // pixel being read
    reg [8:0]  count;                // up to 16x16 = 256 pixels per cell
    reg [8:0]  area;
    reg [12:0] num;                  // count*16 + area/2, the division's dividend
    reg [4:0]  q;                    // quotient being built, 0..16
    reg [2:0]  dbit;                 // which quotient bit we're on, 4 down to 0

    wire px_in = (px >= 0) && (px <= 95) && (py >= 0) && (py <= 63);

    // Address mux: scan uses (sx, sy); cell reads use (px, py) if in range
    assign rd_x = (state == S_SCAN) ? sx : (px_in ? px[6:0] : 7'd0);
    assign rd_y = (state == S_SCAN) ? sy : (px_in ? py[5:0] : 6'd0);

    // width / height / side
    wire [6:0] w = xmax - xmin + 7'd1;
    wire [6:0] h = {1'b0, ymax} - {1'b0, ymin} + 7'd1;
    wire [6:0] side = (w > h) ? w : h;

    // divide-by-CELLS helper: (n * RECIP) >> SHIFT
    function [6:0] divc;
        input [10:0] n;
        reg [20:0] prod;
        begin
            prod  = n * RECIP;
            divc = prod >> SHIFT;
        end
    endfunction

    wire [7:0]  grid_idx = (cy + PAD) * GRID + (cx + PAD);
    wire [10:0] grid_pos = grid_idx * VW;    // first bit of this cell

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            empty <= 1'b1;
            grid  <= 0;
            sx <= 0; sy <= 0; found <= 1'b0;
            tag_valid <= 1'b0; tag_x <= 0; tag_y <= 0;
            xmin <= 0; xmax <= 0; ymin <= 0; ymax <= 0;
            S <= 1; x0 <= 0; y0 <= 0;
            cx <= 0; cy <= 0;
            nxa <= 0; nxb <= 0; nya <= 0; nyb <= 0;
            qxa <= 0; qxb <= 0; qya <= 0; qyb <= 0;
            xs <= 0; xe <= 0; ys <= 0; ye <= 0; px <= 0; py <= 0;
            count <= 0; area <= 0;
            num <= 0; q <= 0; dbit <= 0;
        end else begin
            done <= 1'b0;

            case (state)
            //------------------------------------------------------------
            S_IDLE: begin
                if (start) begin
                    sx <= 0; sy <= 0;
                    found <= 1'b0;
                    tag_valid <= 1'b0;
                    xmin <= 7'd127; xmax <= 7'd0;
                    ymin <= 6'd63;  ymax <= 6'd0;
                    state <= S_SCAN;
                end
            end

            //------------------------------------------------------------
            // 1. SCAN: issue one address per clock, use the data one clock later
            S_SCAN, S_SFLUSH: begin
                if (tag_valid && rd_data) begin
                    found <= 1'b1;
                    if (tag_x < xmin) xmin <= tag_x;
                    if (tag_x > xmax) xmax <= tag_x;
                    if (tag_y < ymin) ymin <= tag_y;
                    if (tag_y > ymax) ymax <= tag_y;
                end
                if (state == S_SCAN) begin
                    tag_valid <= 1'b1;
                    tag_x <= sx;
                    tag_y <= sy;
                    if (sx == 7'd95) begin
                        sx <= 0;
                        if (sy == 6'd63) state <= S_SFLUSH;
                        else             sy <= sy + 6'd1;
                    end else begin
                        sx <= sx + 7'd1;
                    end
                end else begin
                    tag_valid <= 1'b0;
                    state <= S_SIZE;
                end
            end

            //------------------------------------------------------------
            // 2. SIZE
            S_SIZE: begin
                if (!found) begin
                    grid  <= 0;
                    empty <= 1'b1;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    empty <= 1'b0;
                    grid  <= 0;
                    S  <= side;
                    x0 <= $signed({3'd0, xmin}) - $signed({3'd0, (side - w) >> 1});
                    y0 <= $signed({4'd0, ymin}) - $signed({3'd0, (side - h) >> 1});
                    cx <= 0; cy <= 0;
                    state <= S_CA;
                end
            end

            //------------------------------------------------------------
            // 3. CELLS
            S_CA: begin
                nxa <= cx * S;
                nxb <= (cx + 4'd1) * S;
                nya <= cy * S;
                nyb <= (cy + 4'd1) * S;
                state <= S_CB;
            end

            S_CB: begin
                qxa <= divc(nxa);
                qxb <= divc(nxb);
                qya <= divc(nya);
                qyb <= divc(nyb);
                state <= S_CC;
            end

            S_CC: begin : cell_setup
                reg signed [9:0] t_xs, t_xe, t_ys, t_ye;
                t_xs = x0 + $signed({3'd0, qxa});
                t_xe = x0 + $signed({3'd0, qxb});
                t_ys = y0 + $signed({3'd0, qya});
                t_ye = y0 + $signed({3'd0, qyb});
                // a cell must cover at least one pixel (small drawings)
                if (t_xe == t_xs) t_xe = t_xs + 10'sd1;
                if (t_ye == t_ys) t_ye = t_ys + 10'sd1;
                xs <= t_xs; xe <= t_xe;
                ys <= t_ys; ye <= t_ye;
                px <= t_xs; py <= t_ys;
                count <= 0;
                tag_valid <= 1'b0;
                state <= S_CD;
            end

            // area = width x height, from the registered edges. Done in its
            // own clock so the adds above and this multiply don't have to fit
            // in one 10 ns cycle together.
            S_CD: begin
                area  <= (xe - xs) * (ye - ys);
                state <= S_READ;
            end

            // read the cell's pixels one per clock, count ink one clock later
            S_READ, S_RFLUSH: begin
                if (tag_valid && rd_data)
                    count <= count + 9'd1;

                if (state == S_READ) begin
                    tag_valid <= px_in;          // padding pixels count as blank
                    if (px == xe - 10'sd1) begin
                        px <= xs;
                        if (py == ye - 10'sd1) state <= S_RFLUSH;
                        else                   py <= py + 10'sd1;
                    end else begin
                        px <= px + 10'sd1;
                    end
                end else begin
                    tag_valid <= 1'b0;
                    state <= GREY ? S_DIVI : S_DECIDE;
                end
            end

            // Greyscale value = (count*16 + area/2) / area, by long division.
            // Same as dividing on paper in binary: try to subtract area*16,
            // then area*8, area*4, area*2, area*1. Each time it fits, take it
            // away and set that bit of the answer.
            S_DIVI: begin
                num   <= {count, 4'b0000} + {4'd0, area[8:1]};
                q     <= 5'd0;
                dbit  <= 3'd4;
                state <= S_DIV;
            end

            S_DIV: begin : long_div
                reg [12:0] trial;
                trial = {4'd0, area} << dbit;          // area * 2^dbit
                if (num >= trial) begin
                    num     <= num - trial;
                    q[dbit] <= 1'b1;
                end
                if (dbit == 3'd0) state <= S_DECIDE;
                else              dbit  <= dbit - 3'd1;
            end

            S_DECIDE: begin
                if (GREY)
                    grid[grid_pos +: VW] <= q;
                else
                    grid[grid_pos +: VW] <= (({3'd0, count} << TSH) >= {3'd0, area}); // count * 2^TSH >= area
                if (cx == CELLS - 1) begin
                    cx <= 0;
                    if (cy == CELLS - 1) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        cy <= cy + 4'd1;
                        state <= S_CA;
                    end
                end else begin
                    cx <= cx + 4'd1;
                    state <= S_CA;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
