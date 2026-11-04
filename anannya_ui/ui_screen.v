`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ui_screen.v (Anannya) - the renderer: "what colour is pixel (px,py)?"
// Pure combinational: no clock, no state. Moved out of ui_top unchanged.
//////////////////////////////////////////////////////////////////////////////
module ui_screen #(
       parameter MAXLEN = 16
   )(
    input  [6:0] px,
    input  [5:0] py,
    input  [2:0] state,
    input  [3:0] digit,
    input  [MAXLEN*4-1:0] msg,          // our own composed message
    input  [4:0] msg_len,
    input  [MAXLEN*4-1:0] rmsg,         // received message (digits)
    input  [4:0] rmsg_len,
    input  role_rx,                     // 1 = receiver: MSG screen shows rmsg
    input  [1:0] note,                  // 0 none, 1 EMPTY, 2 ERR
    input  [MAXLEN*8-1:0] rx_log,       // raw received bytes
    input  [4:0] rx_n,
    input  link_ok, link_fail,
    input  [6:0] cur_x,
    input  [5:0] cur_y,
    input  oink, has_ink,
    input  [6:0] bxmin, bxmax,
    input  [5:0] bymin, bymax,
    output reg [15:0] pdata
);

    localparam S_DRAW = 3'd0, S_WAIT = 3'd1, S_RESULT = 3'd2, S_MSG = 3'd3, S_RX = 3'd4;
    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, CYAN = 16'h07FF, YELLOW = 16'hFFE0;

    wire msg_full = (msg_len >= MAXLEN);

    //---------------------------------------------------------- shapes on the DRAW screen
    wire signed [8:0] ddx = $signed({2'b00, px}) - $signed({2'b00, cur_x});
    wire signed [8:0] ddy = $signed({3'b000, py}) - $signed({3'b000, cur_y});
    wire on_cursor = ((ddx == 0) && (ddy >= -1) && (ddy <= 1)) ||
                     ((ddy == 0) && (ddx >= -1) && (ddx <= 1));
    wire on_box = has_ink &&
                  ( ((px == bxmin || px == bxmax) && py >= bymin && py <= bymax) ||
                    ((py == bymin || py == bymax) && px >= bxmin && px <= bxmax) );

    //---------------------------------------------------------- text helpers
    function [7:0] d2a;                      // digit -> ASCII, else 'E'
        input [3:0] d;
        begin
            d2a = (d <= 4'd9) ? (8'h30 + {4'd0, d}) : 8'h45;
        end
    endfunction

    function [7:0] h2a;                      // hex digit 0..15 -> '0'-'9','A'-'F'
        input [3:0] h;
        begin
            h2a = (h <= 4'd9) ? (8'h30 + {4'd0, h}) : (8'h37 + {4'd0, h});
        end
    endfunction

    // link status word, used on the MSG and RX screens
    wire [31:0] st_chars = link_ok ? "OK  " : (link_fail ? "FAIL" : "    ");

    // note on the DRAW screen
    wire [39:0] note_chars = (note == 2'd1) ? "EMPTY" : "ERR  ";
    wire t_note;
    text_line #(.N(5), .X0(0), .Y0(0), .SCALE(1)) u_t_note (.px(px), .py(py), .chars(note_chars), .on(t_note));

    // WAIT screen
    wire t_wait;
    text_line #(.N(4), .X0(24), .Y0(25), .SCALE(2)) u_t_wait (.px(px), .py(py), .chars("WAIT"), .on(t_wait));

    // RESULT screen: big digit plus a hint line
    wire [7:0] big_char = d2a(digit);
    wire t_big, t_hint;
    text_line #(.N(1), .X0(38), .Y0(10), .SCALE(4)) u_t_big (.px(px), .py(py), .chars(big_char), .on(t_big));
    wire [95:0] hint_chars = msg_full ? "FULL L:RETRY" : "C:OK L:RETRY";
    text_line #(.N(12), .X0(12), .Y0(48), .SCALE(1)) u_t_hint (.px(px), .py(py), .chars(hint_chars), .on(t_hint));

    // MESSAGE screen: our message, or the received one in receiver role
    wire [MAXLEN*4-1:0] disp_msg = role_rx ? rmsg : msg;
    wire [4:0]          disp_len = role_rx ? rmsg_len : msg_len;

    wire [7:0] len_t = (disp_len >= 5'd10) ? 8'h31 : 8'h30;
    wire [4:0] len_u5 = (disp_len >= 5'd10) ? (disp_len - 5'd10) : disp_len;
    wire [7:0] len_u = 8'h30 + {4'd0, len_u5[3:0]};
    wire [47:0] hdr_chars = {"MSG ", len_t, len_u};
    wire t_hdr, t_ms, t_row1, t_row2, t_mhint;
    text_line #(.N(6), .X0(0),  .Y0(0), .SCALE(1)) u_t_hdr (.px(px), .py(py), .chars(hdr_chars), .on(t_hdr));
    text_line #(.N(4), .X0(66), .Y0(0), .SCALE(1)) u_t_ms  (.px(px), .py(py), .chars(st_chars),  .on(t_ms));

    wire [63:0] row1_chars, row2_chars;
    genvar k, r, j;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_row
            assign row1_chars[(7-k)*8 +: 8] = (k < disp_len)       ? d2a(disp_msg[k*4 +: 4])     : 8'h20;
            assign row2_chars[(7-k)*8 +: 8] = ((k + 8) < disp_len) ? d2a(disp_msg[(k+8)*4 +: 4]) : 8'h20;
        end
    endgenerate
    text_line #(.N(8), .X0(0), .Y0(14), .SCALE(2)) u_t_r1 (.px(px), .py(py), .chars(row1_chars), .on(t_row1));
    text_line #(.N(8), .X0(0), .Y0(32), .SCALE(2)) u_t_r2 (.px(px), .py(py), .chars(row2_chars), .on(t_row2));

    // both branches are exactly 16 characters (96 pixels wide)
    wire [127:0] mhint_chars = role_rx ? {"D:CLR R:LOG", 40'h2020202020} : "C:GO D:CLR R:LOG";
    text_line #(.N(16), .X0(0), .Y0(54), .SCALE(1)) u_t_mh (.px(px), .py(py), .chars(mhint_chars), .on(t_mhint));

    // RX screen: "GOT nn" + OK/FAIL on top, 4 rows of 4 hex bytes, hint line
    wire [7:0]  rn_t  = (rx_n >= 5'd10) ? 8'h31 : 8'h30;
    wire [4:0]  rn_u5 = (rx_n >= 5'd10) ? (rx_n - 5'd10) : rx_n;
    wire [7:0]  rn_u  = 8'h30 + {4'd0, rn_u5[3:0]};
    wire [47:0] rxh_chars = {"GOT ", rn_t, rn_u};
    wire t_gh, t_gs, t_x0, t_x1, t_x2, t_x3, t_ghint;
    text_line #(.N(6), .X0(0),  .Y0(0), .SCALE(1)) u_t_gh (.px(px), .py(py), .chars(rxh_chars), .on(t_gh));
    text_line #(.N(4), .X0(66), .Y0(0), .SCALE(1)) u_t_gs (.px(px), .py(py), .chars(st_chars),  .on(t_gs));

    // each row is 11 chars "AA BB CC DD" (88 bits); byte b shows only if b < rx_n
    wire [351:0] rx_rows;
    generate
        for (r = 0; r < 4; r = r + 1) begin : g_rxr
            for (j = 0; j < 4; j = j + 1) begin : g_rxb
                assign rx_rows[r*88 + (10-3*j)*8 +: 8] =
                    ((r*4+j) < rx_n) ? h2a(rx_log[(r*4+j)*8+4 +: 4]) : 8'h20;
                assign rx_rows[r*88 + (9-3*j)*8 +: 8] =
                    ((r*4+j) < rx_n) ? h2a(rx_log[(r*4+j)*8 +: 4]) : 8'h20;
                if (j < 3) begin : g_sp
                    assign rx_rows[r*88 + (8-3*j)*8 +: 8] = 8'h20;
                end
            end
        end
    endgenerate
    text_line #(.N(11), .X0(15), .Y0(11), .SCALE(1)) u_t_x0 (.px(px), .py(py), .chars(rx_rows[0*88 +: 88]), .on(t_x0));
    text_line #(.N(11), .X0(15), .Y0(21), .SCALE(1)) u_t_x1 (.px(px), .py(py), .chars(rx_rows[1*88 +: 88]), .on(t_x1));
    text_line #(.N(11), .X0(15), .Y0(31), .SCALE(1)) u_t_x2 (.px(px), .py(py), .chars(rx_rows[2*88 +: 88]), .on(t_x2));
    text_line #(.N(11), .X0(15), .Y0(41), .SCALE(1)) u_t_x3 (.px(px), .py(py), .chars(rx_rows[3*88 +: 88]), .on(t_x3));
    text_line #(.N(12), .X0(12), .Y0(54), .SCALE(1)) u_t_gh2 (.px(px), .py(py), .chars("D:CLR R:BACK"), .on(t_ghint));

    //---------------------------------------------------------- colour for this pixel
    // priority mux: the first match wins
    always @* begin
        pdata = BLACK;
        case (state)
            S_DRAW: begin
                if      (on_cursor)               pdata = RED;
                else if (note != 2'd0 && t_note)  pdata = YELLOW;
                else if (oink)                    pdata = WHITE;
                else if (on_box)                  pdata = GREEN;
            end
            S_WAIT: begin
                if (t_wait) pdata = CYAN;
            end
            S_RESULT: begin
                if      (t_big)  pdata = WHITE;
                else if (t_hint) pdata = msg_full ? RED : GREEN;
            end
            S_MSG: begin
                if      (t_hdr)            pdata = YELLOW;
                else if (t_ms)             pdata = link_fail ? RED : GREEN;
                else if (t_row1 | t_row2)  pdata = WHITE;
                else if (t_mhint)          pdata = GREEN;
            end
            S_RX: begin
                if      (t_gh)                          pdata = YELLOW;
                else if (t_gs)                          pdata = link_fail ? RED : GREEN;
                else if (t_x0 | t_x1 | t_x2 | t_x3)     pdata = WHITE;
                else if (t_ghint)                       pdata = GREEN;
            end
        endcase
    end
endmodule