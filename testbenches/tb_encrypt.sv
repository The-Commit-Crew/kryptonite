`timescale 1ns / 1ps

// Run with the repository root as the working directory, or set +data_root.
module tb_encrypt;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst = 1;
    logic start = 0;
    logic [255:0] message = 0;
    wire busy, done;

    wire [2:0] key_poly, noise_poly;
    wire [7:0] source_addr;
    logic [11:0] key_data, fixed_noise_data;
    wire [11:0] sampled_noise_data;
    logic use_live_noise = 0;
    wire [11:0] noise_data = use_live_noise ? sampled_noise_data : fixed_noise_data;
    logic [11:0] keys [0:1535];
    logic [11:0] noise [0:1279];

    logic sampler_start = 0;
    wire sampler_busy, sampler_done;
    logic sampler_readback = 0;
    logic [10:0] sampler_addr = 0;
    logic [11:0] live_noise [0:1279];
    logic [11:0] live_ciphertext [0:767];
    longint unsigned cycles_since_reset;

    wire mul_wr_en, mul_start, mul_done;
    wire [7:0] mul_wr_addr, mul_rd_addr;
    wire [11:0] mul_left, mul_right, mul_rd_data;
    int multiply_count = 0;

    logic [9:0] ciphertext_addr = 0;
    wire [11:0] ciphertext_data;
    logic [11:0] expected [0:767];
    logic [7:0] message_bytes [0:31];
    logic [255:0] fixed_message;
    string data_root, key_dir, noise_dir, expected_dir;
    int message_file, message_size;

    always @(posedge clk) begin
        key_data <= keys[{key_poly, source_addr}];
        fixed_noise_data <= noise[{noise_poly, source_addr}];
        if (rst)
            cycles_since_reset <= 0;
        else
            cycles_since_reset <= cycles_since_reset + 1;
        if (mul_start)
            multiply_count <= multiply_count + 1;
    end

    encrypt_controller dut (
        .clk(clk), .rst(rst), .start(start), .message(message), .busy(busy), .done(done),
        .key_poly(key_poly), .noise_poly(noise_poly), .source_addr(source_addr),
        .key_data(key_data), .noise_data(noise_data),
        .mul_wr_en(mul_wr_en), .mul_wr_addr(mul_wr_addr),
        .mul_left(mul_left), .mul_right(mul_right), .mul_start(mul_start), .mul_done(mul_done),
        .mul_rd_addr(mul_rd_addr), .mul_rd_data(mul_rd_data),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data)
    );

    shared_poly_multiplier multiplier (
        .clk(clk), .rst(rst), .wr_en(mul_wr_en), .wr_addr(mul_wr_addr),
        .left_data(mul_left), .right_data(mul_right), .start(mul_start), .done(mul_done),
        .rd_addr(mul_rd_addr), .rd_data(mul_rd_data)
    );

    noise_sampler sampler (
        .clk(clk), .rst(rst), .start(sampler_start), .busy(sampler_busy), .done(sampler_done),
        .rd_poly(sampler_readback ? sampler_addr[10:8] : noise_poly),
        .rd_addr(sampler_readback ? sampler_addr[7:0] : source_addr),
        .rd_data(sampled_noise_data)
    );

    // Serial reference checks the sampler's parallel bit grouping and advance.
    function automatic logic [63:0] serial_step(input logic [63:0] bits);
        return {bits[62:0], ^(bits & 64'hD800000000000000)};
    endfunction

    task automatic check_sampler(input bit require_new_noise);
        logic [63:0] reference_state;
        logic [11:0] want;
        int eta, difference;
        bit changed;

        reference_state = cycles_since_reset == 0 ? 64'd1 : cycles_since_reset;
        sampler_start = 1;
        @(negedge clk);
        sampler_start = 0;
        if (sampler_busy !== 1'b1)
            $fatal(1, "Sampler did not accept start");
        repeat (1296) @(negedge clk);
        if (sampler_done !== 1'b1 || sampler_busy !== 1'b0)
            $fatal(1, "Sampler did not finish after 16 warm-up and 1280 write cycles");

        repeat (64) reference_state = serial_step(reference_state);
        sampler_readback = 1;
        changed = 0;
        for (int i = 0; i < 1280; i++) begin
            eta = (i < 512) ? 3 : 2;
            difference = 0;
            for (int j = 0; j < 2 * eta; j++) begin
                difference += (j < eta) ? int'(reference_state[63]) : -int'(reference_state[63]);
                reference_state = serial_step(reference_state);
            end
            want = (difference < 0) ? 3329 + difference : difference;
            sampler_addr = i[10:0];
            @(posedge clk);
            #1;
            if (sampled_noise_data !== want)
                $fatal(1, "Noise[%0d]: expected %03h, got %03h", i, want, sampled_noise_data);
            if (sampler_done !== 1'b0)
                $fatal(1, "Expected a one-cycle sampler done pulse");
            if (require_new_noise && live_noise[i] != sampled_noise_data)
                changed = 1;
            live_noise[i] = sampled_noise_data;
            @(negedge clk);
        end
        sampler_readback = 0;
        if (require_new_noise && !changed)
            $fatal(1, "A new counter seed must change the noise");
    endtask

    task automatic run_case(input logic [255:0] plaintext, input bit zero_message);
        int previous_count;
        logic [11:0] want;
        string poly_name;
        begin
            previous_count = multiply_count;
            message = plaintext;
            start = 1;
            @(negedge clk);
            if (busy !== 1'b1)
                $fatal(1, "Controller did not accept start");
            start = 0;
            message = ~plaintext;  // The controller must use the value sampled at start.

            wait (done === 1'b1);
            @(negedge clk);
            if (busy !== 1'b0 || multiply_count - previous_count != 6)
                $fatal(1, "Controller must finish after six multiplies");

            for (int i = 0; i < 768; i++) begin
                ciphertext_addr = i[9:0];
                @(posedge clk);
                #1;
                if (done !== 1'b0)
                    $fatal(1, "Expected a one-cycle done pulse");
                case (i >> 8)
                    0: poly_name = "u0";
                    1: poly_name = "u1";
                    default: poly_name = "v";
                endcase
                want = expected[i];
                // The zero-message case removes the fixed message term from v.
                if (zero_message && i >= 512 && fixed_message[i - 512])
                    want = (int'(want) + 3329 - 1665) % 3329;
                if (use_live_noise) begin
                    if ($isunknown(ciphertext_data) || ciphertext_data >= 12'd3329)
                        $fatal(1, "Invalid live coefficient %s[%0d]", poly_name, i[7:0]);
                    live_ciphertext[i] = ciphertext_data;
                end else if ($isunknown(want) || ciphertext_data !== want)
                    $fatal(1, "%s[%0d]: expected %03h, got %03h (zero_message=%0b)",
                           poly_name, i[7:0], want, ciphertext_data, zero_message);
                @(negedge clk);
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("data_root=%s", data_root))
            data_root = ".";
        key_dir = {data_root, "/crypto/keys/board1/"};
        noise_dir = {data_root, "/crypto/test_vectors/noise/"};
        expected_dir = {data_root, "/crypto/test_vectors/ciphertext/"};

        $readmemh({key_dir, "A00.mem"}, keys,    0,  255);
        $readmemh({key_dir, "A01.mem"}, keys,  256,  511);
        $readmemh({key_dir, "A10.mem"}, keys,  512,  767);
        $readmemh({key_dir, "A11.mem"}, keys,  768, 1023);
        $readmemh({key_dir, "t0.mem"},  keys, 1024, 1279);
        $readmemh({key_dir, "t1.mem"},  keys, 1280, 1535);
        $readmemh({noise_dir, "r0.mem"},   noise,    0,  255);
        $readmemh({noise_dir, "r1.mem"},   noise,  256,  511);
        $readmemh({noise_dir, "e1_0.mem"}, noise,  512,  767);
        $readmemh({noise_dir, "e1_1.mem"}, noise,  768, 1023);
        $readmemh({noise_dir, "e2.mem"},   noise, 1024, 1279);
        $readmemh({expected_dir, "u0.mem"}, expected,   0, 255);
        $readmemh({expected_dir, "u1.mem"}, expected, 256, 511);
        $readmemh({expected_dir, "v.mem"},  expected, 512, 767);

        message_file = $fopen({expected_dir, "message.txt"}, "rb");
        if (message_file == 0)
            $fatal(1, "Unable to open %smessage.txt", expected_dir);
        message_size = $fread(message_bytes, message_file);
        if (message_size != 32 || $fgetc(message_file) != -1)
            $fatal(1, "Expected exactly 32 message bytes");
        $fclose(message_file);
        for (int i = 0; i < 32; i++)
            fixed_message[8*i +: 8] = message_bytes[i];

        repeat (2) @(negedge clk);
        rst = 0;
        run_case(fixed_message, 0);
        $display("PASS: all 768 fixed ciphertext coefficients match Python");
        run_case(256'b0, 1);
        $display("PASS: all 768 zero-message coefficients match after restart");

        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        check_sampler(0);  // Start immediately to exercise the zero counter seed.
        check_sampler(1);
        $display("PASS: all 1280 noise coefficients match the serial reference for both seeds");
        use_live_noise = 1;
        run_case(fixed_message, 0);
        $display("PASS: the controller produced 768 reduced coefficients with live noise");
        if ($test$plusargs("capture_live")) begin
            $writememh("live_noise.mem", live_noise);
            $writememh("live_ciphertext.mem", live_ciphertext);
        end
        $finish;
    end

    initial begin
        #6000000;
        $fatal(1, "Encryption simulation timed out");
    end
endmodule
