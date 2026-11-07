`timescale 1ns / 1ps

// Exercises the actual board top and UI state machine. Debounced button pulses
// and completed digit predictions are supplied at their peripheral boundaries.
module tb_board1_top #(parameter FIXED_NOISE = 1, parameter SIM_MULTIPLIER = 0);
    logic clk = 0;
    always #5 clk = ~clk;
    logic [15:0] sw = 16'h8000;
    wire [15:0] led;
    tri [1:0] JA;
    wire [7:0] JC;
    tri1 PS2Clk, PS2Data;
    logic submit = 0, confirm = 0, retry = 0, clear = 0, next_screen = 0;
    logic pred_valid = 0;
    logic [3:0] pred = 0;
    logic [7:0] keyboard_key = 0;
    logic keyboard_valid = 0;
    wire b_tx;
    logic cut_ab = 0;
    wire b_rx = cut_ab ? 1'b1 : JA[0];
    assign JA[1] = b_tx;

    My_Top_Module #(.SIM_MULTIPLIER(SIM_MULTIPLIER), .FIXED_NOISE(FIXED_NOISE), .BAUD_INC(16'd16384),
                    .ACK_TIMEOUT(40000), .BYTE_TMO(2000), .MAX_RETRY(1)) dut (
        .clk(clk), .sw(sw), .btnC(1'b0), .btnU(1'b0), .btnL(1'b0), .btnR(1'b0), .btnD(1'b0),
        .led(led), .JA(JA), .JC(JC), .PS2Clk(PS2Clk), .PS2Data(PS2Data)
    );

    logic [6:0] b_addr = 0;
    wire [7:0] b_data, b_len, b_type;
    wire b_valid;
    uart_link #(.BAUD_INC(16'd16384), .ACK_TIMEOUT(40000), .BYTE_TMO(2000)) receiver (
        .clk(clk), .rst(dut.rst), .rx_pin(b_rx), .tx_pin(b_tx),
        .tx_wr_en(1'b0), .tx_wr_addr(7'd0), .tx_wr_data(8'd0), .tx_len(8'd0),
        .tx_type(8'h20), .tx_send(1'b0), .tx_busy(), .tx_done(), .tx_fail(),
        .rx_rd_addr(b_addr), .rx_rd_data(b_data), .rx_len(b_len), .rx_type(b_type), .rx_valid(b_valid),
        .fault_inject(1'b0), .tick16_out(), .tx_seq(),
        .cnt_sent(), .cnt_recv(), .cnt_err(), .cnt_retry()
    );

    logic [11:0] fixture [0:767];
    logic [7:0] fixture_message [0:31];
    logic [7:0] received [0:1535];
    string expected_text = "";
    int packets = 0, fragment = 0, offset = 0, next_fragment = 0, multiplies = 0;
    int capture_number = 0;
    longint unsigned cycles_since_reset = 0, sample_seed = 0;
    bit reading = 0;

    always @(posedge clk) begin
        cycles_since_reset <= dut.rst ? 0 : cycles_since_reset + 1;
        if (!dut.rst && dut.u_fsm.encrypted_tx.sender.encryption.accept_send)
            sample_seed = cycles_since_reset;
        if (dut.mul_start)
            multiplies++;
        if (!dut.rst) begin
            if (b_valid) begin
                if (reading || b_len != 128 || b_type < 8'h10 || b_type > 8'h1B)
                    $fatal(1, "Invalid Board 1 packet");
                if (b_type == 8'h10)
                    next_fragment = 0;
                if (b_type != 8'h10 + next_fragment)
                    $fatal(1, "Unexpected packet type %02h", b_type);
                fragment = next_fragment;
                next_fragment++;
                offset = 0;
                b_addr <= 0;
                reading = 1;
            end else if (reading) begin
                int byte_index, coefficient_index, message_index, bit_index;
                logic [11:0] value;
                logic [7:0] character, expected_byte;
                byte_index = fragment * 128 + offset;
                coefficient_index = byte_index / 2;
                value = fixture[coefficient_index];
                if (coefficient_index >= 512) begin
                    message_index = (coefficient_index - 512) / 8;
                    bit_index = (coefficient_index - 512) % 8;
                    character = (message_index < expected_text.len()) ? expected_text[message_index] : 8'h20;
                    value = (int'(value) + 3329 + 1665 *
                            (int'(character[bit_index]) - int'(fixture_message[message_index][bit_index]))) % 3329;
                end
                expected_byte = byte_index[0] ? {4'b0, value[11:8]} : value[7:0];
                if ($isunknown(b_data) || (byte_index[0] && b_data[7:4] != 0))
                    $fatal(1, "Invalid ciphertext byte %0d", byte_index);
                if (FIXED_NOISE && ($isunknown(expected_byte) || b_data !== expected_byte))
                    $fatal(1, "Message %s byte %0d: expected %02h, got %02h",
                           expected_text, byte_index, expected_byte, b_data);
                received[byte_index] = b_data;
                if (offset == 127) begin
                    packets++;
                    reading = 0;
                end else begin
                    offset++;
                    b_addr <= offset;
                end
            end
        end
    end

    task automatic press(input int button);
        case (button)
            0: submit = 1;
            1: confirm = 1;
            2: retry = 1;
            3: clear = 1;
            4: next_screen = 1;
        endcase
        @(negedge clk);
        submit = 0; confirm = 0; retry = 0; clear = 0; next_screen = 0;
        @(negedge clk);
    endtask

    task automatic compose(input string digits);
        if (dut.state == 3) begin
            press(3);
            press(4);
            if (dut.state == 3)  // The first press may close the ciphertext view.
                press(4);
        end
        for (int i = 0; i < digits.len(); i++) begin
            press(0);
            pred = digits[i] - 8'h30;
            pred_valid = 1;
            @(negedge clk);
            pred_valid = 0;
            @(negedge clk);
            if (dut.state !== 3'd2)
                $fatal(1, "UI did not show the predicted digit");
            press(1);
        end
        press(4);
        if (dut.state !== 3'd3 || dut.msg_len != digits.len())
            $fatal(1, "UI did not compose %s", digits);
    endtask

    task automatic expect_success;
        wait (dut.link_ok === 1'b1 || dut.link_fail === 1'b1);
        @(negedge clk);
        if (!dut.link_ok || dut.link_fail || dut.link_busy || packets != 12)
            $fatal(1, "Expected successful delivery of all twelve packets");
        if (dut.u_fsm.encrypted_tx.sender.encryption.busy !== 1'b0)
            $fatal(1, "Ciphertext was not released after acknowledgement");
        capture_number++;
        if ($test$plusargs("capture_top"))
            $writememh($sformatf("top_%0d_%0d_%0d.mem", FIXED_NOISE, capture_number, sample_seed), received);
    endtask

    task automatic keypress(input logic [7:0] key);
        keyboard_key = key;
        keyboard_valid = 1;
        @(negedge clk);
        keyboard_valid = 0;
        @(negedge clk);
    endtask

    task automatic type_message(input string text);
        keypress(8'h1B);
        for (int i = 0; i < text.len(); i++)
            keypress(text[i]);
        if (dut.ed_len != text.len())
            $fatal(1, "Keyboard editor did not retain the complete message");
    endtask

    initial begin
        int file_id;
        force dut.p_submit = submit;
        force dut.p_confirm = confirm;
        force dut.p_retry = retry;
        force dut.p_clear = clear;
        force dut.p_next = next_screen;
        force dut.pred_valid_i = pred_valid;
        force dut.pred_i = pred;
        force dut.empty_i = 1'b0;
        force dut.busy_i = 1'b0;
        force dut.kb_key = keyboard_key;
        force dut.kb_key_v = keyboard_valid;
        $readmemh("crypto/test_vectors/ciphertext/u0.mem", fixture,   0, 255);
        $readmemh("crypto/test_vectors/ciphertext/u1.mem", fixture, 256, 511);
        $readmemh("crypto/test_vectors/ciphertext/v.mem",  fixture, 512, 767);
        file_id = $fopen("crypto/test_vectors/ciphertext/message.txt", "rb");
        if (file_id == 0 || $fread(fixture_message, file_id) != 32)
            $fatal(1, "Missing Python message fixture");
        $fclose(file_id);
        repeat (5) @(negedge clk);
        sw[15] = 0;
        repeat (5) @(negedge clk);

        press(1);
        if (dut.link_busy || multiplies != 0)
            $fatal(1, "Mouse Send outside the MESSAGE screen started encryption");
        compose("379");
        expected_text = "379";
        press(1);
        if (!dut.link_busy || !led[4])
            $fatal(1, "Send did not assert UI busy and its LED");
        compose("15");  // UI edits and another Send must preserve the in-flight snapshot.
        press(1);
        expect_success();
        if (multiplies != 6)
            $fatal(1, "An extra Send was accepted while busy");
        $display("PASS: top-level UI Send delivered all 1536 bytes and preserved its snapshot");

        packets = 0;
        expected_text = "15";
        press(1);
        wait (packets == 4);
        @(negedge clk);
        cut_ab = 1;
        wait (dut.link_fail === 1'b1);
        @(negedge clk);
        if (dut.link_busy || dut.link_ok || multiplies != 12 ||
            !dut.u_fsm.encrypted_tx.sender.encryption.ciphertext_ready)
            $fatal(1, "Failure did not retain the ciphertext and update UI status");
        compose("8");
        packets = 0;
        cut_ab = 0;
        press(2);
        expect_success();
        if (multiplies != 12)
            $fatal(1, "Retry unexpectedly encrypted the edited message");
        $display("PASS: Left after FAIL resent retained ciphertext despite UI edits");

        expected_text = "8";
        packets = 0;
        cut_ab = 1;
        press(1);
        wait (dut.link_fail === 1'b1);
        @(negedge clk);
        compose("2");
        expected_text = "2";
        packets = 0;
        cut_ab = 0;
        press(1);
        expect_success();
        if (multiplies != 24)
            $fatal(1, "New Send after failure did not run a new encryption");
        $display("PASS: Centre after FAIL replaced the retained ciphertext with a new message");

        sw[13] = 1;
        sw[15] = 1;
        repeat (5) @(negedge clk);
        sw[15] = 0;
        repeat (5) @(negedge clk);
        expected_text = " Ee  2026A";
        type_message(expected_text);
        keypress("!");
        if (dut.ed_len != expected_text.len())
            $fatal(1, "Keyboard editor accepted punctuation");
        packets = 0;
        keypress(8'h0D);
        type_message("9876");
        keypress(8'h0D);  // A busy keyboard Send also preserves the snapshot.
        expect_success();
        if (multiplies != 30)
            $fatal(1, "A keyboard Send was accepted while busy");
        $display("PASS: keyboard Enter encrypted letters, digits and spaces and preserved the busy snapshot");

        type_message("0123456789012345");
        expected_text = "0123456789012345";
        packets = 0;
        keypress(8'h0D);
        expect_success();
        if (multiplies != 36)
            $fatal(1, "Full-length keyboard message did not finish one encryption");
        $display("PASS: all sixteen keyboard ASCII bytes were preserved");
        $finish;
    end

    initial begin
        #120000000;
        $fatal(1, "Board 1 top-level integration timed out");
    end
endmodule

module tb_board1_top_live;
    tb_board1_top #(.FIXED_NOISE(0)) test();
endmodule
