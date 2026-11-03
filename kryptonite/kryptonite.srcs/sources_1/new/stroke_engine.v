`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// stroke_engine.v  (Khushi)
//
// Turns cursor movement into ink on the canvas.
//
// Problem it solves: the mouse does not report every pixel it passes over.
// It reports a new position roughly every 10 ms, so a fast stroke jumps
// several pixels at a time. If we only painted the reported points, the
// stroke would be a row of dots. So whenever the cursor moves while a button
// is held, this module draws a straight LINE from the previous point to the
// new point using Bresenham's algorithm (only additions, subtractions and
// comparisons, no division).
//
// Brush: every point on the line is "stamped" with a square brush of size
// 1x1, 3x3 or 5x5 pixels (brush_sel = 0, 1, 2), chosen with switches.
//
// Live bounding box: while painting, it keeps the smallest and largest x and
// y of all inked pixels. The UI can draw this box on the OLED in real time.
// (It only grows; erasing does not shrink it. The downsampler re-scans the
// whole canvas on submit, so the final crop is always exact.)
//
// Clear: wipes all 6144 pixels, one per clock (about 61 microseconds).
//////////////////////////////////////////////////////////////////////////////
module stroke_engine (
    input  wire       clk,
    input  wire       rst,

    input  wire [6:0] cursor_x,     // 0..95 (from the mouse / UI)
    input  wire [5:0] cursor_y,     // 0..63
    input  wire       paint,        // held = draw ink
    input  wire       erase,        // held = rub out (ignored if paint is held)
    input  wire       clear,        // one-clock pulse = wipe canvas
    input  wire [1:0] brush_sel,    // 0: 1x1, 1: 3x3, 2 or 3: 5x5
    input  wire       enable,       // 0 = ignore pen (e.g. while downsampling)

    // write port into canvas_mem port A
    output reg  [6:0] wr_x,
    output reg  [5:0] wr_y,
    output reg        wr_en,
    output reg        wr_data,

    output wire       busy,         // 1 while drawing a line or clearing

    // live bounding box of ink painted since the last clear
    output reg        has_ink,
    output reg  [6:0] box_xmin,
    output reg  [6:0] box_xmax,
    output reg  [5:0] box_ymin,
    output reg  [5:0] box_ymax
);
    localparam S_IDLE  = 2'd0;
    localparam S_STAMP = 2'd1;   // stamping the brush around the current point
    localparam S_STEP  = 2'd2;   // move one step along the line
    localparam S_CLEAR = 2'd3;

    reg [1:0] state;
    assign busy = (state != S_IDLE);

    // Line endpoints and Bresenham state. Signed so negatives work.
    reg signed [9:0] x, y;        // current point on the line
    reg signed [9:0] x1, y1;      // end point
    reg signed [9:0] dx, dy;      // dx = |x1-x0|, dy = -|y1-y0|
    reg signed [9:0] sx, sy;      // step direction: +1 or -1
    reg signed [9:0] err;

    // Brush stamping offsets
    reg signed [9:0] bx, by;      // -r .. +r
    reg signed [9:0] r;           // brush radius: 0, 1 or 2
    reg              ink;         // value being written (1 paint, 0 erase)

    reg [6:0] last_x;
    reg [5:0] last_y;
    reg       was_down;           // pen was down on the previous point
    reg       clear_pending;
    reg [6:0] clr_x;
    reg [5:0] clr_y;

    wire pen_down = (paint | erase) & enable;

    // Pixel being stamped right now
    wire signed [9:0] px = x + bx;
    wire signed [9:0] py = y + by;
    wire px_ok = (px >= 0) && (px <= 95) && (py >= 0) && (py <= 63);

    // One Bresenham step (computed combinationally from the current state)
    wire signed [10:0] e2     = {err, 1'b0};   // e2 = 2 * err
    wire signed [10:0] dx_ext = dx;            // sign-extended copies so the
    wire signed [10:0] dy_ext = dy;            // comparisons below are signed
    wire step_x = (e2 >= dy_ext);
    wire step_y = (e2 <= dx_ext);
    wire signed [9:0] err_after_x = step_x ? (err + dy) : err;
    wire signed [9:0] err_next    = step_y ? (err_after_x + dx) : err_after_x;
    wire at_end = (x == x1) && (y == y1);

    // Helper: start a line from (fx,fy) to (tx,ty)
    task start_line;
        input [6:0] fx;
        input [5:0] fy;
        input [6:0] tx;
        input [5:0] ty;
        reg signed [9:0] adx, ady;
        begin
            x  <= {3'd0, fx};
            y  <= {4'd0, fy};
            x1 <= {3'd0, tx};
            y1 <= {4'd0, ty};
            adx = (tx >= fx) ? ({3'd0, tx} - {3'd0, fx}) : ({3'd0, fx} - {3'd0, tx});
            ady = (ty >= fy) ? ({4'd0, ty} - {4'd0, fy}) : ({4'd0, fy} - {4'd0, ty});
            dx  <= adx;
            dy  <= -ady;
            sx  <= (tx >= fx) ? 10'sd1 : -10'sd1;
            sy  <= (ty >= fy) ? 10'sd1 : -10'sd1;
            err <= adx - ady;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_CLEAR;   // wipe the canvas after reset
            clr_x <= 0; clr_y <= 0;
            clear_pending <= 1'b0;
            wr_en         <= 1'b0;
            wr_x <= 0; wr_y <= 0; wr_data <= 0;
            was_down      <= 1'b0;
            last_x <= 0; last_y <= 0;
            x <= 0; y <= 0; x1 <= 0; y1 <= 0;
            dx <= 0; dy <= 0; sx <= 1; sy <= 1; err <= 0;
            bx <= 0; by <= 0; r <= 0; ink <= 1'b1;
            has_ink  <= 1'b0;
            box_xmin <= 7'd127; box_xmax <= 7'd0;
            box_ymin <= 6'd63;  box_ymax <= 6'd0;
        end else begin
            wr_en <= 1'b0;
            if (clear) clear_pending <= 1'b1;

            case (state)
            //----------------------------------------------------------
            S_IDLE: begin
                if (clear_pending) begin
                    clear_pending <= 1'b0;
                    clr_x <= 0; clr_y <= 0;
                    state <= S_CLEAR;
                end else if (pen_down) begin
                    // Pen just went down: draw a single point.
                    // Pen already down and cursor moved: line from last point.
                    if (!was_down || (cursor_x != last_x) || (cursor_y != last_y)) begin
                        if (!was_down)
                            start_line(cursor_x, cursor_y, cursor_x, cursor_y);
                        else
                            start_line(last_x, last_y, cursor_x, cursor_y);
                        last_x <= cursor_x;
                        last_y <= cursor_y;
                        ink <= paint;   // paint wins if both buttons are held
                        case (brush_sel)
                            2'd0:    r <= 10'sd0;
                            2'd1:    r <= 10'sd1;
                            default: r <= 10'sd2;
                        endcase
                        case (brush_sel)
                            2'd0:    begin bx <= 10'sd0;  by <= 10'sd0;  end
                            2'd1:    begin bx <= -10'sd1; by <= -10'sd1; end
                            default: begin bx <= -10'sd2; by <= -10'sd2; end
                        endcase
                        state <= S_STAMP;
                    end
                    was_down <= 1'b1;
                end else begin
                    was_down <= 1'b0;
                end
            end

            //----------------------------------------------------------
            // Write one brush pixel per clock: bx goes -r..r, then by.
            S_STAMP: begin
                if (px_ok) begin
                    wr_x    <= px[6:0];
                    wr_y    <= py[5:0];
                    wr_data <= ink;
                    wr_en   <= 1'b1;
                    if (ink) begin
                        has_ink <= 1'b1;
                        if (px[6:0] < box_xmin) box_xmin <= px[6:0];
                        if (px[6:0] > box_xmax) box_xmax <= px[6:0];
                        if (py[5:0] < box_ymin) box_ymin <= py[5:0];
                        if (py[5:0] > box_ymax) box_ymax <= py[5:0];
                    end
                end
                if (bx == r) begin
                    bx <= -r;
                    if (by == r) begin
                        by    <= -r;
                        state <= at_end ? S_IDLE : S_STEP;
                    end else begin
                        by <= by + 10'sd1;
                    end
                end else begin
                    bx <= bx + 10'sd1;
                end
            end

            //----------------------------------------------------------
            // Bresenham: move to the next pixel on the line, then stamp it
            S_STEP: begin
                if (step_x) x <= x + sx;
                if (step_y) y <= y + sy;
                err   <= err_next;
                state <= S_STAMP;
            end

            //----------------------------------------------------------
            S_CLEAR: begin
                // walk every pixel, x fastest, writing 0
                wr_x    <= clr_x;
                wr_y    <= clr_y;
                wr_data <= 1'b0;
                wr_en   <= 1'b1;
                if (clr_x == 7'd95) begin
                    clr_x <= 0;
                    clr_y <= clr_y + 6'd1;
                end else begin
                    clr_x <= clr_x + 7'd1;
                end
                if (clr_x == 7'd95 && clr_y == 6'd63) begin
                    state    <= S_IDLE;
                    was_down <= 1'b0;
                    has_ink  <= 1'b0;
                    box_xmin <= 7'd127; box_xmax <= 7'd0;
                    box_ymin <= 6'd63;  box_ymax <= 6'd0;
                end
            end
            endcase
        end
    end
endmodule
