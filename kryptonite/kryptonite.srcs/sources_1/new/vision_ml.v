`timescale 1ns / 1ps

// Drawing-to-digit pipeline for the UI. Submit is a one-clock pulse while idle.
module vision_ml (
    input  wire         clk,
    input  wire         rst,
    input  wire [6:0]   cursor_x,
    input  wire [5:0]   cursor_y,
    input  wire         paint,
    input  wire         erase,
    input  wire         clear,
    input  wire [1:0]   brush_sel,
    input  wire         submit,

    input  wire [6:0]   oled_x,
    input  wire [5:0]   oled_y,
    output wire         oled_ink,
    output wire         has_ink,
    output wire [6:0]   box_xmin,
    output wire [6:0]   box_xmax,
    output wire [5:0]   box_ymin,
    output wire [5:0]   box_ymax,

    output wire [319:0] grid,
    output wire         grid_valid,
    output wire         grid_empty,
    output wire         busy,
    output wire [3:0]   prediction,
    output wire         prediction_valid
);
    wire vision_busy, grid_ready;
    wire ml_busy, ml_done;
    wire cancel = rst | clear;
    reg waiting_for_grid;
    reg canvas_clear_pending;
    reg canvas_clear_dispatched;

    // The downsampler owns the canvas port while busy. Wait before erasing it.
    wire clear_canvas = (clear | canvas_clear_pending) & ~vision_busy;
    assign busy = vision_busy | waiting_for_grid | ml_busy |
                  canvas_clear_pending | canvas_clear_dispatched;
    wire accept_submit = submit & ~busy & ~cancel;
    assign grid_valid = grid_ready & waiting_for_grid & ~cancel;
    assign prediction_valid = ml_done & ~cancel;

    // Keep busy asserted through the grid handoff. Clearing this flag also
    // discards a stale grid if clear arrives during downsampling.
    always @(posedge clk) begin
        // The stroke engine needs one cycle to pick up its queued clear.
        canvas_clear_dispatched <= clear_canvas & ~rst;
        if (rst)
            canvas_clear_pending <= 1'b0;
        else
            canvas_clear_pending <= (clear | canvas_clear_pending) & vision_busy;

        if (cancel || grid_ready)
            waiting_for_grid <= 1'b0;
        else if (accept_submit)
            waiting_for_grid <= 1'b1;
    end

    vision_top #(.GRID(8), .GREY(1)) u_vision (
        .clk(clk), .rst(rst),
        .cursor_x(cursor_x), .cursor_y(cursor_y),
        .paint(paint), .erase(erase), .clear(clear_canvas),
        .brush_sel(brush_sel), .submit(accept_submit),
        .oled_x(oled_x), .oled_y(oled_y), .oled_ink(oled_ink),
        .has_ink(has_ink), .box_xmin(box_xmin), .box_xmax(box_xmax),
        .box_ymin(box_ymin), .box_ymax(box_ymax),
        .grid(grid), .grid_valid(grid_ready), .grid_empty(grid_empty),
        .busy(vision_busy)
    );

    tinyml_core u_ml (
        .clk(clk), .clear(cancel), .start(grid_valid & ~grid_empty),
        .pixels(grid), .prediction(prediction), .done(ml_done), .busy(ml_busy)
    );
endmodule
