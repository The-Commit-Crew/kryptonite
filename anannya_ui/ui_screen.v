`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// ui_screen.v (Anannya) - the renderer: "what colour is pixel (px,py)?"
// Pure combinational: no clock, no state.
//  state 0 DRAW  1 WAIT  2 RESULT  3 MSG (our digits)  4 RX (received)  5 COMPOSE (typing)
//////////////////////////////////////////////////////////////////////////////
module ui_screen #(
    parameter MAXLEN = 16
)(
    input  [6:0] px,
    input  [5:0] py,
    input  [2:0] state,
    input  [3:0] digit,
    input  [MAXLEN*8-1:0] msg,          // our own message (ASCII, byte 0 = first)
    input  [4:0] msg_len,
    input  [MAXLEN*8-1:0] rx_log,       // received bytes
    input  [4:0] rx_n,
    input  rx_hex,                      // RX screen: 1 = hex, 0 = text
    input  role_kb,                     // keyboard board (changes the RX hint)
    input  blink,                       // text cursor on/off
    input  [1:0] note,                  // 0 none, 1 EMPTY, 2 ERR
    input  link_ok, link_fail,
    input  [6:0] cur_x,
    input  [5:0] cur_y,
    input  oink, has_ink,
    input  [6:0] bxmin, bxmax,
    input  [5:0] bymin, bymax,
    input toolbar_valid,
    input  [15:0] toolbar_pdata,
    output reg [15:0] pdata
);
    localparam S_DRAW = 3'd0, S_WAIT = 3'd1, S_RESULT = 3'd2,
               S_MSG  = 3'd3, S_RX   = 3'd4, S_COMPOSE = 3'd5;
    localparam WHITE = 16'hFFFF, BLACK = 16'h0000, RED = 16'hF800,
               GREEN = 16'h07E0, CYAN = 16'h07FF, YELLOW = 16'hFFE0;

    wire msg_full = (msg_len >= MAXLEN);
    wire in_rx    = (state == S_RX);

    //---------------------------------------------------------- shapes on the DRAW screen
    wire signed [8:0] ddx = $signed({2'b00, px}) - $signed({2'b00, cur_x});
    wire signed [8:0] ddy = $signed({3'b000, py}) - $signed({3'b000, cur_y});
    wire on_cursor = !role_kb && (state <= S_RX) &&
                     (((ddx == 0) && (ddy >= -1) && (ddy <= 1)) ||
                      ((ddy == 0) && (ddx >= -1) && (ddx <= 1)));
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

    function [7:0] h2a;                      // 0..15 -> '0'-'9','A'-'F'
        input [3:0] h;
        begin
            h2a = (h <= 4'd9) ? (8'h30 + {4'd0, h}) : (8'h37 + {4'd0, h});
        end
    endfunction

    function [7:0] dchar;                    // lower case letters are drawn as upper case
        input [7:0] c;
        begin
            dchar = (c >= 8'h61 && c <= 8'h7A) ? (c - 8'h20) : c;
        end
    endfunction

    // DRAW note
    wire [39:0] note_chars = (note == 2'd1) ? "EMPTY" : "ERR  ";
    wire t_note;
    text_line #(.N(5), .X0(0), .Y0(0), .SCALE(1)) u_t_note (.px(px), .py(py), .chars(note_chars), .on(t_note));

    // WAIT
    wire t_wait;
    text_line #(.N(4), .X0(24), .Y0(25), .SCALE(2)) u_t_wait (.px(px), .py(py), .chars("WAIT"), .on(t_wait));

    // RESULT: the big digit
    wire [7:0] big_char = d2a(digit);
    wire t_big;
    text_line #(.N(1), .X0(38), .Y0(10), .SCALE(4)) u_t_big (.px(px), .py(py), .chars(big_char), .on(t_big));

    //---------------------------------------------------------- shared by MSG / COMPOSE / RX
    // header: "MSG nn" / "TYPE nn" / "GOT nn"
    wire [4:0] hl     = in_rx ? rx_n : msg_len;
    wire [7:0] len_t  = (hl >= 5'd10) ? 8'h31 : 8'h30;
    wire [4:0] len_u5 = (hl >= 5'd10) ? (hl - 5'd10) : hl;
    wire [7:0] len_u  = 8'h30 + {4'd0, len_u5[3:0]};
    reg  [55:0] hdr_chars;
    always @* begin
        case (state)
            S_COMPOSE: hdr_chars = {"TYPE ", len_t, len_u};
            S_RX:      hdr_chars = {"GOT ",  len_t, len_u, " "};
            default:   hdr_chars = {"MSG ",  len_t, len_u, " "};
        endcase
    end
    wire t_hdr, t_stat;
    text_line #(.N(7), .X0(0),  .Y0(0), .SCALE(1)) u_t_hdr (.px(px), .py(py), .chars(hdr_chars), .on(t_hdr));
    wire [31:0] st_chars = link_ok ? "OK  " : (link_fail ? "FAIL" : "    ");
    text_line #(.N(4), .X0(66), .Y0(0), .SCALE(1)) u_t_stat (.px(px), .py(py), .chars(st_chars), .on(t_stat));

    // two rows of 8 characters (scale 2): our message, or the received one on the RX screen
    wire [MAXLEN*8-1:0] src = in_rx ? rx_log : msg;
    wire [63:0] row1_chars, row2_chars;
    genvar k, r, j;
    generate
        for (k = 0; k < 8; k = k + 1) begin : g_row
            assign row1_chars[(7-k)*8 +: 8] = (k < hl)       ? dchar(src[k*8 +: 8])     : 8'h20;
            assign row2_chars[(7-k)*8 +: 8] = ((k + 8) < hl) ? dchar(src[(k+8)*8 +: 8]) : 8'h20;
        end
    endgenerate
    wire t_row1, t_row2;
    text_line #(.N(8), .X0(0), .Y0(14), .SCALE(2)) u_t_r1 (.px(px), .py(py), .chars(row1_chars), .on(t_row1));
    text_line #(.N(8), .X0(0), .Y0(32), .SCALE(2)) u_t_r2 (.px(px), .py(py), .chars(row2_chars), .on(t_row2));

    // RX hex view: 4 rows of 4 bytes "AA BB CC DD"
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
    wire t_x0, t_x1, t_x2, t_x3;
    text_line #(.N(11), .X0(15), .Y0(11), .SCALE(1)) u_t_x0 (.px(px), .py(py), .chars(rx_rows[0*88 +: 88]), .on(t_x0));
    text_line #(.N(11), .X0(15), .Y0(21), .SCALE(1)) u_t_x1 (.px(px), .py(py), .chars(rx_rows[1*88 +: 88]), .on(t_x1));
    text_line #(.N(11), .X0(15), .Y0(31), .SCALE(1)) u_t_x2 (.px(px), .py(py), .chars(rx_rows[2*88 +: 88]), .on(t_x2));
    text_line #(.N(11), .X0(15), .Y0(41), .SCALE(1)) u_t_x3 (.px(px), .py(py), .chars(rx_rows[3*88 +: 88]), .on(t_x3));

    wire t_body = (in_rx && rx_hex) ? (t_x0 | t_x1 | t_x2 | t_x3) : (t_row1 | t_row2);

    // one 16-character hint line at the bottom, chosen by screen (every string is exactly 16 chars)
    reg [127:0] hint;
    always @* begin
        case (state)
            S_RESULT:  hint = msg_full ? "  FULL L:RETRY  " : "  C:OK L:RETRY  ";
            S_MSG:     hint = "C:GO D:CLR R:LOG";
            S_COMPOSE: hint = "ENT:SEND ESC:CLR";
            S_RX:      hint = role_kb ? " TAB:BACK D:CLR " : "  D:CLR R:BACK  ";
            default:   hint = "                ";
        endcase
    end
    wire t_hint;
    text_line #(.N(16), .X0(0), .Y0(54), .SCALE(1)) u_t_hint (.px(px), .py(py), .chars(hint), .on(t_hint));

    // text cursor on the COMPOSE screen: a 2-pixel underline under the next free slot
    wire [6:0] ucx = msg_len[2:0] * 7'd12;
    wire [5:0] ucy = (msg_len[3] ? 6'd32 : 6'd14) + 6'd14;
    wire on_ucur = blink && !msg_len[4] &&
                   (py >= ucy) && (py <= ucy + 6'd1) && (px >= ucx) && (px <= ucx + 7'd9);

    //---------------------------------------------------------- colour for this pixel
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
            S_MSG, S_RX, S_COMPOSE: begin
                if      (t_hdr)                              pdata = YELLOW;
                else if (t_stat)                             pdata = link_fail ? RED : GREEN;
                else if (t_body)                             pdata = WHITE;
                else if (state == S_COMPOSE && on_ucur)      pdata = CYAN;
                else if (t_hint)                             pdata = GREEN;
            end
            default: ;
        endcase
        if (toolbar_valid)
            pdata = toolbar_pdata;
        if (on_cursor)
            pdata = RED;
    end
endmodule