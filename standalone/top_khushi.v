`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// top_khushi.v  (Khushi) - STANDALONE TEST TOP for my part only
//
// Lets me test and demo everything I own on ONE board, before the UI, ML and
// crypto parts exist. In the final project, My_Top_Module instantiates
// vision_top and uart_link directly and this file is not used.
//
// Draw with the mouse -> press submit -> 8x8 (or 16x16) grid is made -> sent as a
// packet over the UART link -> received -> shown on the OLED. The grid is
// also sent to the PC over USB for collecting training drawings.
//
// Controls
//   Mouse left   paint          Mouse right  erase       Mouse middle  clear
//   btnC  reset                 btnU  submit (make grid + send)
//   btnD  clear canvas          btnL  fault inject (corrupt next packet)
//   btnR  next 7-seg counter (S sent, r received, E errors, n re-sends)
//   sw[1:0]  brush: 00 = 1 px, 01 = 3x3, 1x = 5x5
//   sw[3:2]  view:  00 = canvas, 01 = my grid, 10 = received grid
//   sw[4]    1 = internal loopback (TX goes straight to my own RX)
//            0 = use the JA cable to the other board
//   LEDs: 0 grid empty, 1 link busy, 2 last send OK, 3 last send FAILED,
//         4 vision busy, 15..8 current TX sequence number
//////////////////////////////////////////////////////////////////////////////
module top_khushi #(
    parameter GRID = 8                // 8 -> 8x8 grid (64 bits), 16 -> 16x16
)(
    input  wire        clk,
    input  wire        btnC, btnU, btnD, btnL, btnR,
    input  wire [15:0] sw,
    output reg  [15:0] led,
    output wire [6:0]  seg,
    output wire [3:0]  an,
    output wire        dp,
    output wire [7:0]  JC,            // Pmod OLED
    inout  wire        PS2Clk,
    inout  wire        PS2Data,
    output wire        JA_TX,         // JA1 -> other board's JA2
    input  wire        JA_RX,         // JA2 <- other board's JA1
    output wire        RsTx           // USB-UART to PC
);
    //------------------------------------------------------------ reset, buttons
    wire rst;
    wire p_submit, p_clear, p_fault, p_next;
    debounce d_c (.clk(clk), .btn(btnC), .level(rst),  .pulse());
    debounce d_u (.clk(clk), .btn(btnU), .level(),     .pulse(p_submit));
    debounce d_d (.clk(clk), .btn(btnD), .level(),     .pulse(p_clear));
    debounce d_l (.clk(clk), .btn(btnL), .level(),     .pulse(p_fault));
    debounce d_r (.clk(clk), .btn(btnR), .level(),     .pulse(p_next));

    //------------------------------------------------------------ mouse
    // MouseCtl's default range is x 0..959, y 0..639, so /10 gives 96 x 64.
    wire [11:0] xpos, ypos;
    wire [3:0]  zpos;
    wire        m_left, m_mid, m_right, m_new;
    MouseCtl u_mouse (
        .clk(clk), .rst(rst),
        .xpos(xpos), .ypos(ypos), .zpos(zpos),
        .left(m_left), .middle(m_mid), .right(m_right), .new_event(m_new),
        .value(12'd0), .setx(1'b0), .sety(1'b0), .setmax_x(1'b0), .setmax_y(1'b0),
        .ps2_clk(PS2Clk), .ps2_data(PS2Data));

    // divide by 10 with a fixed-point reciprocal: n/10 = (n*3277) >> 15,
    // exact for n = 0..4095 (checked in Python), no divider circuit needed
    wire [23:0] xm = xpos * 12'd3277;
    wire [23:0] ym = ypos * 12'd3277;
    wire [11:0] xd = xm[23:15];
    wire [11:0] yd = ym[23:15];
    wire [6:0]  cur_x = (xd > 95) ? 7'd95 : xd[6:0];
    wire [5:0]  cur_y = (yd > 63) ? 6'd63 : yd[5:0];

    // middle click -> one clear pulse
    reg mid_q;
    always @(posedge clk) mid_q <= m_mid;
    wire mid_pulse = m_mid & ~mid_q;

    //------------------------------------------------------------ vision
    wire [6:0]   ox;
    wire [5:0]   oy;
    wire         oink;
    wire         has_ink;
    wire [6:0]   bxmin, bxmax;
    wire [5:0]   bymin, bymax;
    localparam GBITS  = GRID * GRID;      // 64 or 256
    localparam GBYTES = GBITS / 8;        // 8 or 32 bytes per packet
    localparam [7:0] GLEN = GBYTES;       // same, as an 8-bit length field
    wire [GBITS-1:0] grid;
    wire         grid_valid, grid_empty, v_busy;

    vision_top #(.GRID(GRID)) u_vision (
        .clk(clk), .rst(rst),
        .cursor_x(cur_x), .cursor_y(cur_y),
        .paint(m_left), .erase(m_right & ~m_left),
        .clear(p_clear | mid_pulse), .brush_sel(sw[1:0]), .submit(p_submit),
        .oled_x(ox), .oled_y(oy), .oled_ink(oink),
        .has_ink(has_ink),
        .box_xmin(bxmin), .box_xmax(bxmax), .box_ymin(bymin), .box_ymax(bymax),
        .grid(grid), .grid_valid(grid_valid), .grid_empty(grid_empty),
        .busy(v_busy));

    //------------------------------------------------------------ UART link
    localparam T_GRID = 8'h20;
    reg         l_we;
    reg  [6:0]  l_wa;
    reg  [7:0]  l_wd;
    reg         l_send;
    wire        l_busy, l_done, l_fail, l_rxv;
    reg  [6:0]  l_ra;
    wire [7:0]  l_rd, l_rlen, l_rtype, l_seq;
    wire [11:0] c_s, c_r, c_e, c_n;
    wire        tick16;
    wire        link_tx;
    wire        link_rx = sw[4] ? link_tx : JA_RX;
    assign JA_TX = link_tx;

    uart_link u_link (
        .clk(clk), .rst(rst), .rx_pin(link_rx), .tx_pin(link_tx),
        .tx_wr_en(l_we), .tx_wr_addr(l_wa), .tx_wr_data(l_wd),
        .tx_len(GLEN), .tx_type(T_GRID), .tx_send(l_send),
        .tx_busy(l_busy), .tx_done(l_done), .tx_fail(l_fail),
        .rx_rd_addr(l_ra), .rx_rd_data(l_rd), .rx_len(l_rlen),
        .rx_type(l_rtype), .rx_valid(l_rxv),
        .fault_inject(p_fault), .tick16_out(tick16), .tx_seq(l_seq),
        .cnt_sent(c_s), .cnt_recv(c_r), .cnt_err(c_e), .cnt_retry(c_n));

    // after a new non-empty grid: copy its 32 bytes into the TX buffer, send
    reg [GBITS-1:0] tx_grid;
    reg [5:0]   wr_i;
    reg         loading;
    always @(posedge clk) begin
        if (rst) begin
            loading <= 0; wr_i <= 0; l_we <= 0; l_wa <= 0; l_wd <= 0; l_send <= 0;
            tx_grid <= 0;
        end else begin
            l_we <= 1'b0;
            l_send <= 1'b0;
            if (!loading) begin
                if (grid_valid && !grid_empty && !l_busy) begin
                    tx_grid <= grid;
                    wr_i    <= 0;
                    loading <= 1'b1;
                end
            end else if (wr_i == GBYTES) begin
                l_send  <= 1'b1;
                loading <= 1'b0;
            end else begin
                l_we <= 1'b1;
                l_wa <= {1'b0, wr_i};
                l_wd <= tx_grid[wr_i*8 +: 8];
                wr_i <= wr_i + 6'd1;
            end
        end
    end

    // when a grid packet arrives: read its 32 bytes into rx_grid
    reg [GBITS-1:0] rx_grid;
    reg [5:0]   rd_i;
    reg         reading;
    always @(posedge clk) begin
        if (rst) begin
            reading <= 0; rd_i <= 0; l_ra <= 0; rx_grid <= 0;
        end else if (!reading) begin
            if (l_rxv && l_rtype == T_GRID && l_rlen == GBYTES) begin
                reading <= 1'b1;
                rd_i    <= 0;
                l_ra    <= 0;
            end
        end else begin
            // l_rd is combinational from l_ra
            rx_grid[rd_i*8 +: 8] <= l_rd;
            if (rd_i == GBYTES - 1) reading <= 1'b0;
            rd_i <= rd_i + 6'd1;
            l_ra <= l_ra + 7'd1;
        end
    end

    //------------------------------------------------------------ PC dump
    grid_dump #(.GBYTES(GBYTES)) u_dump (.clk(clk), .rst(rst), .tick16(tick16),
                      .trigger(grid_valid & ~grid_empty), .grid(grid), .usb_tx(RsTx));

    //------------------------------------------------------------ 7-segment
    seg7_stats u_seg (.clk(clk), .rst(rst), .next(p_next),
                      .cnt_sent(c_s), .cnt_recv(c_r), .cnt_err(c_e), .cnt_retry(c_n),
                      .seg(seg), .an(an), .dp(dp));

    //------------------------------------------------------------ LEDs
    reg last_ok, last_fail;
    always @(posedge clk) begin
        if (rst) begin last_ok <= 0; last_fail <= 0; end
        else if (l_done) begin last_ok <= 1; last_fail <= 0; end
        else if (l_fail) begin last_ok <= 0; last_fail <= 1; end
    end
    always @(*) begin
        led = 16'd0;
        led[0] = grid_empty;
        led[1] = l_busy;
        led[2] = last_ok;
        led[3] = last_fail;
        led[4] = v_busy;
        led[15:8] = l_seq;
    end

    //------------------------------------------------------------ OLED
    reg [3:0] cdiv = 0;
    reg       clk6p25 = 0;
    always @(posedge clk) begin
        cdiv <= cdiv + 4'd1;
        if (cdiv == 4'd7) begin
            cdiv <= 0;
            clk6p25 <= ~clk6p25;      // 100 MHz / 16 = 6.25 MHz
        end
    end

    wire [12:0] pix;
    reg  [15:0] pdata;
    wire [6:0]  px;
    wire [5:0]  py;
    pix_to_xy u_p2xy (.pix(pix), .x(px), .y(py));
    assign ox = px;
    assign oy = py;

    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, GREY = 16'h2104, CYAN = 16'h07FF;

    wire on_cursor = ((px == cur_x) && (py >= cur_y - 1) && (py <= cur_y + 1)) ||
                     ((py == cur_y) && (px >= cur_x - 1) && (px <= cur_x + 1));
    wire on_box = has_ink &&
                  (((px == bxmin || px == bxmax) && py >= bymin && py <= bymax) ||
                   ((py == bymin || py == bymax) && px >= bxmin && px <= bxmax));
    // grid preview in a 64x64 square at x = 16..79:
    // 8x8 grid -> each cell 8x8 pixels, 16x16 grid -> each cell 4x4 pixels
    wire        in_prev = (px >= 16) && (px < 80);
    wire [6:0]  gx = px - 7'd16;
    wire [7:0]  gidx = (GRID == 16) ? {py[5:2], gx[5:2]}           // row*16 + col
                                    : {2'b00, py[5:3], gx[5:3]};   // row*8 + col

    always @(*) begin
        case (sw[3:2])
            2'b01: pdata = !in_prev ? BLACK : (grid[gidx]    ? WHITE : GREY);
            2'b10: pdata = !in_prev ? BLACK : (rx_grid[gidx] ? CYAN  : GREY);
            default: begin
                if (on_cursor)   pdata = RED;
                else if (oink)   pdata = WHITE;
                else if (on_box) pdata = GREEN;
                else             pdata = BLACK;
            end
        endcase
    end

    Oled_Display u_oled (
        .clk(clk6p25), .reset(rst),
        .frame_begin(), .sending_pixels(), .sample_pixel(),
        .pixel_index(pix), .pixel_data(pdata),
        .cs(JC[0]), .sdin(JC[1]), .sclk(JC[3]), .d_cn(JC[4]),
        .resn(JC[5]), .vccen(JC[6]), .pmoden(JC[7]));
    assign JC[2] = 1'b0;
endmodule
