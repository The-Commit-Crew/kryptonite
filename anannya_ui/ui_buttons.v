`timescale 1ns / 1ps

module ui_buttons #(
    parameter REPEAT_DIV = 1_000_000,
    parameter INITIAL_REPEAT_DIV = REPEAT_DIV * 8,
    parameter FLASH_DIV  = 15_000_000
)(
    input wire       clk,
    input wire       rst,
    input wire       role_kb,
    input wire       debug_en,
    input wire [2:0] state,
    input wire       rx_role,      // Khushi: 1 = receiver board (RX: DECRY / FLIP / CLR)
    input wire       tx_ct_view,   // Khushi: sender is showing its ciphertext (MSG: PLAIN)
    input wire       self_mode,    // Khushi: self test (MSG: RX, RX: DECRY / CLR / BACK)
    input wire [6:0] mouse_x,
    input wire [5:0] mouse_y,
    input wire       mouse_left,
    input wire       mouse_right,
    input wire       btn_u_level,
    input wire       btn_c_level,
    input wire       btn_l_level,
    input wire       btn_r_level,
    input wire       btn_d_level,
    input wire [6:0] px,
    input wire [5:0] py,
    output wire [6:0] cur_x,
    output wire [5:0] cur_y,
    output wire       left,
    output wire       right,
    output reg        click_submit,
    output reg        click_confirm,
    output reg        click_retry,
    output reg        click_clear,
    output reg        click_next,
    output wire       paint_ok,
    output wire       erase_ok,
    output reg        toolbar_valid,
    output reg [15:0] toolbar_pdata
);
    localparam S_DRAW = 3'd0, S_WAIT = 3'd1, S_RESULT = 3'd2,
               S_MSG  = 3'd3, S_RX   = 3'd4, S_COMPOSE = 3'd5;
    localparam [15:0] BLACK = 16'h0000, WHITE = 16'hFFFF,
                      BLUE = 16'h3186, BLUE_HI = 16'h5ACB,
                      YELLOW = 16'hFFE0, CYAN = 16'h07FF;

    wire debug_active = debug_en && !role_kb;
    reg [6:0] fake_x = 7'd48;
    reg [5:0] fake_y = 6'd32;
    reg [23:0] repeat_count = 24'd0;
    reg repeat_started = 1'b0;
    reg initial_repeat_wait = 1'b0;
    reg debug_q = 1'b0;
    reg left_q = 1'b0;
    reg start_on_button = 1'b0;
    reg [3:0] flash_button = 4'd0;
    reg [23:0] flash_count = 24'd0;

    assign cur_x = debug_active ? fake_x : mouse_x;
    assign cur_y = debug_active ? fake_y : mouse_y;
    assign left  = debug_active ? btn_c_level : mouse_left;
    assign right = debug_active ? 1'b0 : mouse_right;

    wire has_toolbar = !role_kb && (state != S_COMPOSE) && (state <= S_RX);
    wire in_toolbar = has_toolbar && (cur_y >= 6'd54);
    reg [39:0] label0, label1, label2;
    reg valid0, valid1, valid2;
    always @* begin
        label0 = "     "; label1 = "     "; label2 = "     ";
        valid0 = 1'b0; valid1 = 1'b0; valid2 = 1'b0;
        if (has_toolbar) begin
            case (state)
                S_DRAW: begin label0 = "SEND "; label1 = "CLR  "; label2 = "MSG  "; valid0 = 1'b1; valid1 = 1'b1; valid2 = 1'b1; end
                S_WAIT: begin label0 = "STOP "; valid0 = 1'b1; end
                S_RESULT: begin label0 = "OK   "; label1 = "RETRY"; valid0 = 1'b1; valid1 = 1'b1; end
                S_MSG: begin
                    label0 = "SEND "; label1 = "CLR  ";
                    // sender board: third button shows the digits again, or goes back to DRAW
                    label2 = tx_ct_view ? "PLAIN" : (self_mode ? "RX   " : "DRAW ");
                    valid0 = 1'b1; valid1 = 1'b1; valid2 = 1'b1;
                end
                S_RX: begin
                    if (rx_role) begin       // receiver board
                        label0 = "DECRY"; label1 = "FLIP "; label2 = "CLR  ";
                        valid0 = 1'b1; valid1 = 1'b1; valid2 = 1'b1;
                    end else if (self_mode) begin   // self test: decrypt your own message
                        label0 = "DECRY"; label1 = "CLR  "; label2 = "BACK ";
                        valid0 = 1'b1; valid1 = 1'b1; valid2 = 1'b1;
                    end else begin
                        label0 = "CLR  "; label1 = "BACK "; valid0 = 1'b1; valid1 = 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

    wire b0 = in_toolbar && valid0 && (cur_x <= 7'd30);
    wire b1 = in_toolbar && valid1 && (cur_x >= 7'd33) && (cur_x <= 7'd63);
    wire b2 = in_toolbar && valid2 && (cur_x >= 7'd66);
    wire hover_button = b0 || b1 || b2;
    wire [1:0] hover_index = b1 ? 2'd1 : (b2 ? 2'd2 : 2'd0);
    wire left_rise = left && !left_q;

    assign paint_ok = left && !start_on_button && (cur_y < 6'd54);
    assign erase_ok = right && (cur_y < 6'd54) && !start_on_button;

    wire text0, text1, text2;
    text_line #(.N(5), .X0(3),  .Y0(56), .SCALE(1)) u_label0 (.px(px), .py(py), .chars(label0), .on(text0));
    text_line #(.N(5), .X0(35), .Y0(56), .SCALE(1)) u_label1 (.px(px), .py(py), .chars(label1), .on(text1));
    text_line #(.N(5), .X0(67), .Y0(56), .SCALE(1)) u_label2 (.px(px), .py(py), .chars(label2), .on(text2));

    wire pixel_b0 = valid0 && (px <= 7'd30) && (py >= 6'd54) && (py <= 6'd63);
    wire pixel_b1 = valid1 && (px >= 7'd33) && (px <= 7'd63) && (py >= 6'd54) && (py <= 6'd63);
    wire pixel_b2 = valid2 && (px >= 7'd66) && (py >= 6'd54) && (py <= 6'd63);
    wire pixel_button = pixel_b0 || pixel_b1 || pixel_b2;
    wire [1:0] pixel_index = pixel_b1 ? 2'd1 : (pixel_b2 ? 2'd2 : 2'd0);
    wire pixel_text = (pixel_index == 2'd0 && text0) ||
                      (pixel_index == 2'd1 && text1) ||
                      (pixel_index == 2'd2 && text2);
    wire pixel_hover = hover_button && (hover_index == pixel_index);
    wire pixel_flash = (flash_count != 0) && (flash_button == {2'd0, pixel_index});

    // green cyber style (Khushi): outlined buttons, green text; hover lights the
    // fill and turns the text white; a click flashes the button bright green.
    localparam [15:0] T_GRN = 16'h2FF1, T_DIM = 16'h0368, T_FILL = 16'h0225;
    wire pixel_edge = pixel_button && (py == 6'd54 || py == 6'd63 ||
                      px == 7'd0 || px == 7'd30 || px == 7'd33 || px == 7'd63 ||
                      px == 7'd66 || px == 7'd95);
    always @* begin
        toolbar_valid = pixel_button;
        if (pixel_flash)
            toolbar_pdata = pixel_text ? BLACK : T_GRN;
        else if (pixel_text)
            toolbar_pdata = pixel_hover ? WHITE : T_GRN;
        else if (pixel_edge)
            toolbar_pdata = pixel_hover ? T_GRN : T_DIM;
        else
            toolbar_pdata = pixel_hover ? T_FILL : BLACK;
    end

    always @(posedge clk) begin
        click_submit  <= 1'b0;
        click_confirm <= 1'b0;
        click_retry   <= 1'b0;
        click_clear   <= 1'b0;
        click_next    <= 1'b0;
        left_q       <= left;
        debug_q      <= debug_active;

        if (rst) begin
            fake_x <= 7'd48;
            fake_y <= 6'd32;
            repeat_count <= 24'd0;
            repeat_started <= 1'b0;
            initial_repeat_wait <= 1'b0;
            left_q <= 1'b0;
            debug_q <= 1'b0;
            start_on_button <= 1'b0;
            flash_button <= 4'd0;
            flash_count <= 24'd0;
        end else begin
            if (!left)
                start_on_button <= 1'b0;
            if (left_rise) begin
                start_on_button <= hover_button;
                if (hover_button) begin
                    flash_button <= {2'd0, hover_index};
                    flash_count <= FLASH_DIV;
                    case (state)
                        S_DRAW: begin
                            if (hover_index == 2'd0) click_submit <= 1'b1;
                            else if (hover_index == 2'd1) click_clear <= 1'b1;
                            else click_next <= 1'b1;
                        end
                        S_WAIT: click_clear <= 1'b1;
                        S_RESULT: begin
                            if (hover_index == 2'd0) click_confirm <= 1'b1;
                            else click_retry <= 1'b1;
                        end
                        S_MSG: begin
                            if (hover_index == 2'd0) click_confirm <= 1'b1;
                            else if (hover_index == 2'd1) click_clear <= 1'b1;
                            else click_next <= 1'b1;
                        end
                        S_RX: begin
                            if (rx_role) begin                       // DECRY / FLIP / CLR
                                if (hover_index == 2'd0) click_confirm <= 1'b1;
                                else if (hover_index == 2'd1) click_next <= 1'b1;
                                else click_clear <= 1'b1;
                            end else if (self_mode) begin            // DECRY / CLR / BACK
                                if (hover_index == 2'd0) click_confirm <= 1'b1;
                                else if (hover_index == 2'd1) click_clear <= 1'b1;
                                else click_next <= 1'b1;
                            end else begin
                                if (hover_index == 2'd0) click_clear <= 1'b1;
                                else click_next <= 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end
            end

            if (flash_count != 0)
                flash_count <= flash_count - 24'd1;

            if (debug_active) begin
                if (!debug_q) begin
                    fake_x <= mouse_x;
                    fake_y <= mouse_y;
                    repeat_count <= 24'd0;
                    repeat_started <= 1'b0;
                    initial_repeat_wait <= 1'b0;
                end else if (btn_u_level || btn_d_level || btn_l_level || btn_r_level) begin
                    if (!repeat_started) begin
                        if (btn_l_level && fake_x != 0) fake_x <= fake_x - 7'd1;
                        if (btn_r_level && fake_x != 7'd95) fake_x <= fake_x + 7'd1;
                        if (btn_u_level && fake_y != 0) fake_y <= fake_y - 6'd1;
                        if (btn_d_level && fake_y != 6'd63) fake_y <= fake_y + 6'd1;
                        repeat_count <= 24'd0;
                        repeat_started <= 1'b1;
                    end else if (!initial_repeat_wait) begin
                        if (repeat_count >= INITIAL_REPEAT_DIV - 1) begin
                            repeat_count <= 24'd0;
                            initial_repeat_wait <= 1'b1;
                        end else begin
                            repeat_count <= repeat_count + 24'd1;
                        end
                    end else if (repeat_count >= REPEAT_DIV - 1) begin
                        if (btn_l_level && fake_x != 0) fake_x <= fake_x - 7'd1;
                        if (btn_r_level && fake_x != 7'd95) fake_x <= fake_x + 7'd1;
                        if (btn_u_level && fake_y != 0) fake_y <= fake_y - 6'd1;
                        if (btn_d_level && fake_y != 6'd63) fake_y <= fake_y + 6'd1;
                        repeat_count <= 24'd0;
                    end else begin
                        repeat_count <= repeat_count + 24'd1;
                    end
                end else begin
                    repeat_count <= 24'd0;
                    repeat_started <= 1'b0;
                    initial_repeat_wait <= 1'b0;
                end
            end
        end
    end
endmodule