`timescale 1ns / 1ps

// Run from the repository root or stage the crypto fixtures under the run directory.
module tb_board1_send;
    logic clk = 0;
    always #5 clk = ~clk;
    wire fixed_finished, live_finished;

    board1_send_case #(.FIXED_NOISE(1)) fixed_case (.clk(clk), .finished(fixed_finished));
    board1_send_case #(.FIXED_NOISE(0)) live_case (.clk(clk), .finished(live_finished));

    initial begin
        wait (fixed_finished && live_finished);
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "Board 1 Send simulation timed out");
    end
endmodule

module board1_send_case #(parameter FIXED_NOISE = 0) (
    input logic clk,
    output logic finished = 0
);
    logic rst = 1, send_req = 0, ciphertext_release = 0;
    logic [63:0] msg_in = 0;
    logic [4:0] msg_len_in = 0;
    logic [9:0] ciphertext_addr = 0;
    wire busy, ciphertext_ready;
    wire [11:0] ciphertext_data;

    wire mul_wr_en, mul_start, mul_done;
    wire [7:0] mul_wr_addr, mul_rd_addr;
    wire [11:0] mul_left, mul_right, mul_rd_data;
    int multiply_count = 0;
    int cycles_since_reset = 0;

    logic [11:0] expected [0:767];
    logic [7:0] reference_bytes [0:31];
    logic [11:0] captured [0:767];

    always @(posedge clk) begin
        cycles_since_reset <= rst ? 0 : cycles_since_reset + 1;
        if (mul_start)
            multiply_count <= multiply_count + 1;
    end

    board1_send #(.FIXED_NOISE(FIXED_NOISE)) dut (
        .clk(clk), .rst(rst), .send_req(send_req), .msg_in(msg_in), .msg_len_in(msg_len_in),
        .busy(busy), .ciphertext_ready(ciphertext_ready), .ciphertext_release(ciphertext_release),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr), .mul_left(mul_left),
        .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
        .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data)
    );

    poly_mult_model multiplier (
        .clk(clk), .rst(rst), .wr_en(mul_wr_en), .wr_addr(mul_wr_addr),
        .left_data(mul_left), .right_data(mul_right), .start(mul_start), .done(mul_done),
        .rd_addr(mul_rd_addr), .rd_data(mul_rd_data)
    );

    task automatic run_send(input logic [63:0] digits, input string ascii, input int case_number);
        int count_before, seed, byte_index, bit_index;
        logic [7:0] expected_byte;
        logic [11:0] want;

        count_before = multiply_count;
        seed = cycles_since_reset;
        msg_in = digits;
        msg_len_in = ascii.len();
        send_req = 1;
        @(negedge clk);
        send_req = 0;
        if (busy !== 1'b1 || ciphertext_ready !== 1'b0)
            $fatal(1, "Send did not begin with busy asserted");

        // Simulate editing the UI message and pressing Send again during encryption.
        msg_in = 64'h8;
        msg_len_in = 1;
        @(negedge clk);
        send_req = 1;
        @(negedge clk);
        send_req = 0;

        wait (ciphertext_ready === 1'b1);
        @(negedge clk);
        // A new Send must also be ignored while the consumer owns the ciphertext.
        send_req = 1;
        @(negedge clk);
        send_req = 0;
        for (int i = 0; i < 768; i++) begin
            ciphertext_addr = i[9:0];
            @(posedge clk);
            #1;
            if (busy !== 1'b1 || ciphertext_ready !== 1'b1 || multiply_count != count_before + 6)
                $fatal(1, "Ciphertext was not held ready after exactly six products");
            if ($isunknown(ciphertext_data) || ciphertext_data >= 12'd3329)
                $fatal(1, "Invalid ciphertext coefficient at address %0d", i);

            if (FIXED_NOISE) begin
                want = expected[i];
                // u is unchanged. For v, replace the Python fixture's encoded
                // message bit with the expected digit or padding bit.
                if (i >= 512) begin
                    byte_index = (i - 512) / 8;
                    bit_index = (i - 512) % 8;
                    expected_byte = (byte_index < ascii.len()) ? ascii[byte_index] : 8'h20;
                    want = (int'(want) + 3329 + 1665 *
                           (int'(expected_byte[bit_index]) - int'(reference_bytes[byte_index][bit_index]))) % 3329;
                end
                if ($isunknown(want) || ciphertext_data !== want)
                    $fatal(1, "Send %0d coefficient %0d: expected %03h, got %03h",
                           case_number, i, want, ciphertext_data);
            end
            captured[i] = ciphertext_data;
            @(negedge clk);
        end

        if ($test$plusargs("capture_send"))
            $writememh($sformatf("board1_%0d_%0d_%0d.mem", FIXED_NOISE, case_number, seed), captured);
        ciphertext_release = 1;
        @(negedge clk);
        ciphertext_release = 0;
        if (busy !== 1'b0 || ciphertext_ready !== 1'b0)
            $fatal(1, "Ciphertext release did not return Send to idle");
    endtask

    initial begin
        if (FIXED_NOISE) begin
            int message_file;
            $readmemh("crypto/test_vectors/ciphertext/u0.mem", expected,   0, 255);
            $readmemh("crypto/test_vectors/ciphertext/u1.mem", expected, 256, 511);
            $readmemh("crypto/test_vectors/ciphertext/v.mem",  expected, 512, 767);
            message_file = $fopen("crypto/test_vectors/ciphertext/message.txt", "rb");
            if (message_file == 0)
                $fatal(1, "Unable to open the fixed Python message");
            if ($fread(reference_bytes, message_file) != 32 || $fgetc(message_file) != -1)
                $fatal(1, "Expected 32 bytes in the fixed Python message");
            $fclose(message_file);
        end

        repeat (2) @(negedge clk);
        rst = 0;
        send_req = 1;  // Ignore an empty UI message.
        @(negedge clk);
        send_req = 0;
        if (busy !== 1'b0)
            $fatal(1, "Empty UI message unexpectedly started a Send");
        repeat (17) @(negedge clk);
        run_send(64'h973, "379", 1);
        run_send(64'h5432109876543210, "0123456789012345", 2);
        if (FIXED_NOISE)
            $display("PASS: both fixed-noise sends matched all 768 coefficients");
        else
            $display("PASS: both live-noise sends produced 768 reduced coefficients");
        finished = 1;
    end
endmodule
