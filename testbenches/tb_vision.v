`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// tb_vision.v  (Khushi) - tests stroke_engine + canvas_mem + downsampler
//
// Reads tb/stim_vision.txt, one line per event:
//      x y paint erase brush submit clear
// For each event it sets the inputs, waits until the engine is idle again,
// and after every 'submit' it writes the canvas and grid to files that
// tb/check_vision.py compares with the Python reference.
//
// Run from the project folder:
//   python3 tb/gen_vision.py
//   iverilog -g2005 -o sim_vision tb/tb_vision.v rtl/vision_top.v rtl/stroke_engine.v rtl/canvas_mem.v rtl/downsampler.v
//   vvp sim_vision
//   python3 tb/check_vision.py
// In Vivado: add the rtl files as design sources and this file as a
// simulation source, set tb_vision as top, and put the stim file in the
// simulation run folder (or use an absolute path below).
//////////////////////////////////////////////////////////////////////////////
module tb_vision;
    parameter GRID = 8;             // 8 or 16; run gen/check with the same GRID
    reg clk = 0;
    always #5 clk = ~clk;           // 100 MHz

    reg rst = 1;
    reg [6:0] cx = 0;
    reg [5:0] cy = 0;
    reg paint = 0, erase = 0, clear = 0, submit = 0;
    reg [1:0] bsel = 0;

    wire [GRID*GRID-1:0] grid;
    wire grid_valid, grid_empty, busy;
    wire has_ink;
    wire [6:0] bxmin, bxmax;
    wire [5:0] bymin, bymax;
    wire oled_ink;

    vision_top #(.GRID(GRID)) dut (
        .clk(clk), .rst(rst),
        .cursor_x(cx), .cursor_y(cy),
        .paint(paint), .erase(erase), .clear(clear),
        .brush_sel(bsel), .submit(submit),
        .oled_x(7'd0), .oled_y(6'd0), .oled_ink(oled_ink),
        .has_ink(has_ink),
        .box_xmin(bxmin), .box_xmax(bxmax), .box_ymin(bymin), .box_ymax(bymax),
        .grid(grid), .grid_valid(grid_valid), .grid_empty(grid_empty),
        .busy(busy)
    );

    integer fin, fout, n, i, k;
    integer x, y, p, e, b, s, c;
    reg got_grid;

    always @(posedge clk) if (grid_valid) got_grid <= 1;

    task wait_idle;
        begin
            @(posedge clk); @(posedge clk); @(posedge clk);
            while (busy) @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        got_grid = 0;
        fin  = $fopen("C:/Users/madna/Downloads/kryptonite_khushi/kryptonite_khushi/tb/stim_vision.txt", "r");
fout = $fopen("C:/Users/madna/Downloads/kryptonite_khushi/kryptonite_khushi/tb/out_vision.txt", "w");
        if (fin == 0) begin $display("cannot open tb/stim_vision.txt"); $finish; end
        repeat (5) @(posedge clk);
        rst = 0;
        wait_idle;                         // reset clears the canvas

        while (!$feof(fin)) begin
            n = $fscanf(fin, "%d %d %d %d %d %d %d\n", x, y, p, e, b, s, c);
            if (n == 7) begin
                @(negedge clk);
                cx = x; cy = y; paint = p; erase = e; bsel = b;
                if (c) begin clear = 1; @(negedge clk); clear = 0; end
                wait_idle;
                if (s) begin
                    got_grid = 0;
                    @(negedge clk); submit = 1; @(negedge clk); submit = 0;
                    while (!got_grid) @(posedge clk);
                    // dump canvas
                    for (k = 0; k < 6144; k = k + 1)
                        $fwrite(fout, "%0d", dut.u_canvas.mem[k]);
                    $fwrite(fout, "\n");
                    for (k = 0; k < GRID*GRID; k = k + 1)
                        $fwrite(fout, "%0d", grid[k]);
                    $fwrite(fout, " %0d %0d %0d %0d %0d\n", grid_empty, bxmin, bxmax, bymin, bymax);
                end
            end
        end
        $fclose(fout);
        $display("tb_vision finished at %0t ns", $time);
        $finish;
    end
endmodule
