`timescale 1ns / 1ps

// Run with crypto/test_vectors/ciphertext available under the working directory.
module tb_ciphertext_serializer;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1, start = 0;
    wire busy, done;
    wire [9:0] ciphertext_addr;
    logic [11:0] ciphertext_data;
    logic [11:0] ciphertext [0:767];
    wire [7:0] byte_data;
    wire byte_valid, byte_last;
    logic byte_ready = 0, stalls = 0;
    int accepted = 0, cycles = 0, last_hold = 0;
    bit held_last = 0, previously_stalled = 0;
    logic [7:0] previous_byte;
    logic previous_last;

    ciphertext_serializer dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .byte_data(byte_data), .byte_valid(byte_valid), .byte_last(byte_last), .byte_ready(byte_ready)
    );

    always @(posedge clk)
        ciphertext_data <= ciphertext[ciphertext_addr];

    always @(negedge clk) begin
        if (rst) begin
            cycles = 0;
            last_hold = 0;
            held_last = 0;
            byte_ready = 0;
        end else begin
            cycles++;
            if (stalls && byte_last && !held_last) begin
                last_hold = 11;
                held_last = 1;
            end
            byte_ready = !stalls || (last_hold == 0 && cycles % 7 < 3 && cycles % 31 < 25);
            if (last_hold > 0)
                last_hold--;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            accepted = 0;
            previously_stalled = 0;
        end else begin
            if (previously_stalled &&
                (byte_valid !== 1'b1 || byte_data !== previous_byte || byte_last !== previous_last))
                $fatal(1, "Output changed while the byte consumer was stalled");
            if (start && !busy) begin
                accepted = 0;
                held_last = 0;
            end
            if (byte_valid) begin
                if (!busy || ciphertext_addr >= 768 || accepted >= 1536)
                    $fatal(1, "Unexpected output byte or coefficient address");
                if (byte_last !== (accepted == 1535))
                    $fatal(1, "byte_last was wrong at byte %0d", accepted);
                if (byte_ready) begin
                    if (byte_data !== (accepted[0] ? {4'b0, ciphertext[accepted / 2][11:8]}
                                                                : ciphertext[accepted / 2][7:0]))
                        $fatal(1, "Python vector mismatch at byte %0d", accepted);
                    accepted++;
                end
            end
            previously_stalled = byte_valid && !byte_ready;
            previous_byte = byte_data;
            previous_last = byte_last;
        end
    end

    task automatic start_stream(input bit stall_consumer);
        stalls = stall_consumer;
        start = 1;
        @(negedge clk);
        start = 0;
        if (busy !== 1'b1)
            $fatal(1, "Serializer did not accept start");
    endtask

    task automatic finish_stream;
        wait (done === 1'b1);
        @(negedge clk);
        if (accepted != 1536 || busy !== 1'b0 || byte_valid !== 1'b0)
            $fatal(1, "Serializer did not finish after exactly 1536 accepted bytes");
        @(negedge clk);
        if (done !== 1'b0)
            $fatal(1, "Expected a one-cycle done pulse");
    endtask

    initial begin
        $readmemh("crypto/test_vectors/ciphertext/u0.mem", ciphertext,   0, 255);
        $readmemh("crypto/test_vectors/ciphertext/u1.mem", ciphertext, 256, 511);
        $readmemh("crypto/test_vectors/ciphertext/v.mem",  ciphertext, 512, 767);
        for (int i = 0; i < 768; i++)
            if ($isunknown(ciphertext[i]))
                $fatal(1, "Missing ciphertext fixture at coefficient %0d", i);

        repeat (2) @(negedge clk);
        rst = 0;
        start_stream(0);
        finish_stream();
        $display("PASS: all 1536 bytes match the Python vector without stalls");

        start_stream(1);
        // A second start during the stream must be ignored.
        repeat (13) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        finish_stream();
        if (!held_last)
            $fatal(1, "The final byte stall was not exercised");
        $display("PASS: all 1536 bytes match with backpressure and a stalled final byte");

        start_stream(1);
        wait (accepted == 17);
        @(negedge clk);
        rst = 1;
        repeat (2) @(negedge clk);
        if (busy !== 1'b0 || byte_valid !== 1'b0 || done !== 1'b0)
            $fatal(1, "Reset did not abort serialization");
        rst = 0;
        start_stream(1);
        finish_stream();
        $display("PASS: reset aborts serialization and the next stream restarts at u0[0]");
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "Ciphertext serializer simulation timed out");
    end
endmodule
