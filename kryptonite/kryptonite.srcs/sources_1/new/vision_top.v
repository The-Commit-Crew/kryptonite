`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// vision_top.v  (Khushi)
//
// Everything on the drawing side in one box, so teammates only connect to
// these ports:
//
//   Anannya (UI)   -> cursor_x/y, paint, erase, clear, brush_sel, submit
//   Anannya (UI)   <- oled_x/y -> oled_ink   (to draw the canvas on screen)
//                  <- live box (to draw a rectangle around the drawing)
//                  <- grid     (to show the grid preview)
//   Shrikkanth(ML) <- grid[GRID*GRID-1:0] + grid_valid pulse (+ grid_empty)
//
// Canvas port A is shared: the stroke engine uses it while drawing, and the
// downsampler uses it while busy. Drawing is paused while downsampling
// (it takes about 0.1 ms, far too short for a person to notice).
//////////////////////////////////////////////////////////////////////////////
module vision_top #(
    parameter GRID  = 8,              // 8 -> 8x8 grid, 16 -> 16x16 grid
    parameter PAD   = (GRID == 16) ? 2 : 1,
    parameter RECIP = 683,
    parameter SHIFT = (GRID == 16) ? 13 : 12,
    parameter TSH   = (GRID == 16) ? 2 : 3     // ink threshold: 25% or 12.5%
)(
    input  wire         clk,          // 100 MHz
    input  wire         rst,

    // pen input
    input  wire [6:0]   cursor_x,     // 0..95
    input  wire [5:0]   cursor_y,     // 0..63
    input  wire         paint,
    input  wire         erase,
    input  wire         clear,        // pulse
    input  wire [1:0]   brush_sel,    // 0: 1px, 1: 3x3, 2: 5x5
    input  wire         submit,       // pulse: make the grid

    // OLED read port (1 clock latency)
    input  wire [6:0]   oled_x,
    input  wire [5:0]   oled_y,
    output wire         oled_ink,

    // live bounding box while drawing
    output wire         has_ink,
    output wire [6:0]   box_xmin,
    output wire [6:0]   box_xmax,
    output wire [5:0]   box_ymin,
    output wire [5:0]   box_ymax,

    // result for the classifier
    output wire [GRID*GRID-1:0] grid, // grid[row*GRID + col]
    output wire         grid_valid,   // one-clock pulse
    output wire         grid_empty,
    output wire         busy
);
    // stroke engine -> canvas
    wire [6:0] se_x;
    wire [5:0] se_y;
    wire       se_we, se_din, se_busy;

    // downsampler -> canvas
    wire [6:0] ds_x;
    wire [5:0] ds_y;
    wire       ds_busy;

    wire       a_dout;

    // Register the pen inputs first. The cursor usually comes from a mouse
    // calculation (divide by 10, clamp), and feeding that straight into the
    // stroke engine's line setup made one long path that failed timing at
    // 100 MHz. Storing it in flip-flops splits that path in two. Cost: one
    // clock (10 ns) of delay, which nobody can notice.
    reg [6:0] cx_q;
    reg [5:0] cy_q;
    reg       paint_q, erase_q;
    always @(posedge clk) begin
        cx_q    <= cursor_x;
        cy_q    <= cursor_y;
        paint_q <= paint;
        erase_q <= erase;
    end

    // hold a submit request until the stroke engine has finished its line
    reg submit_pending;
    wire ds_start = submit_pending & ~se_busy & ~ds_busy;
    always @(posedge clk) begin
        if (rst)            submit_pending <= 1'b0;
        else if (submit)    submit_pending <= 1'b1;
        else if (ds_start)  submit_pending <= 1'b0;
    end

    stroke_engine u_stroke (
        .clk(clk), .rst(rst),
        .cursor_x(cx_q), .cursor_y(cy_q),
        .paint(paint_q), .erase(erase_q), .clear(clear),
        .brush_sel(brush_sel),
        .enable(~ds_busy & ~submit_pending),
        .wr_x(se_x), .wr_y(se_y), .wr_en(se_we), .wr_data(se_din),
        .busy(se_busy),
        .has_ink(has_ink),
        .box_xmin(box_xmin), .box_xmax(box_xmax),
        .box_ymin(box_ymin), .box_ymax(box_ymax)
    );

    canvas_mem u_canvas (
        .clk(clk),
        .a_x (ds_busy ? ds_x : se_x),
        .a_y (ds_busy ? ds_y : se_y),
        .a_we(ds_busy ? 1'b0 : se_we),
        .a_din(se_din),
        .a_dout(a_dout),
        .b_x(oled_x), .b_y(oled_y), .b_dout(oled_ink)
    );

    downsampler #(.GRID(GRID), .PAD(PAD), .RECIP(RECIP), .SHIFT(SHIFT), .TSH(TSH)) u_ds (
        .clk(clk), .rst(rst), .start(ds_start),
        .rd_x(ds_x), .rd_y(ds_y), .rd_data(a_dout),
        .busy(ds_busy), .done(grid_valid), .empty(grid_empty), .grid(grid),
        .xmin(), .xmax(), .ymin(), .ymax()
    );

    assign busy = se_busy | ds_busy | submit_pending;
endmodule