`timescale 1ns / 1ps

// Two real uart_link instances exercise packet transmission over serial wires.
// Stage crypto/test_vectors/ciphertext under the simulation working directory.
module tb_ciphertext_uart_tx;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1, start = 0;
    wire busy, done, fail;
    wire [9:0] ciphertext_addr;
    logic [11:0] ciphertext_data;
    logic [11:0] ciphertext [0:767];
    logic [7:0] received_bytes [0:1535];

    wire a_tx, b_tx;
    logic cut_ab = 0, cut_ba = 0, fault_inject = 0;
    wire a_rx = cut_ba ? 1'b1 : b_tx;
    wire b_rx = cut_ab ? 1'b1 : a_tx;
    wire a_we, a_send, a_busy, a_done, a_fail;
    wire [6:0] a_wa;
    wire [7:0] a_wd, a_len, a_type;
    wire [11:0] a_retries;
    logic [6:0] b_addr = 0;
    wire [7:0] b_data, b_len, b_type;
    wire b_valid;

    int received_packets = 0, packet_requests = 0, expected_fragment = 0;
    int read_index = 0, read_fragment = 0;
    bit reading = 0, drop_one_ack = 0, ack_dropped = 0;
    int ack_drop_left = 0;
    bit previous_done = 0, previous_fail = 0;

    always @(posedge clk)
        ciphertext_data <= ciphertext[ciphertext_addr];

    ciphertext_uart_tx dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done), .fail(fail),
        .ciphertext_addr(ciphertext_addr), .ciphertext_data(ciphertext_data),
        .tx_wr_en(a_we), .tx_wr_addr(a_wa), .tx_wr_data(a_wd), .tx_len(a_len),
        .tx_type(a_type), .tx_send(a_send), .tx_busy(a_busy), .tx_done(a_done), .tx_fail(a_fail)
    );

    uart_link #(.BYTE_TMO(2000), .ACK_TIMEOUT(40000), .MAX_RETRY(2), .BAUD_INC(16'd16384)) A (
        .clk(clk), .rst(rst), .rx_pin(a_rx), .tx_pin(a_tx),
        .tx_wr_en(a_we), .tx_wr_addr(a_wa), .tx_wr_data(a_wd), .tx_len(a_len),
        .tx_type(a_type), .tx_send(a_send), .tx_busy(a_busy), .tx_done(a_done), .tx_fail(a_fail),
        .rx_rd_addr(7'd0), .rx_rd_data(), .rx_len(), .rx_type(), .rx_valid(),
        .fault_inject(fault_inject), .tick16_out(), .tx_seq(),
        .cnt_sent(), .cnt_recv(), .cnt_err(), .cnt_retry(a_retries)
    );

    uart_link #(.BYTE_TMO(2000), .ACK_TIMEOUT(40000), .MAX_RETRY(2), .BAUD_INC(16'd16384)) B (
        .clk(clk), .rst(rst), .rx_pin(b_rx), .tx_pin(b_tx),
        .tx_wr_en(1'b0), .tx_wr_addr(7'd0), .tx_wr_data(8'd0), .tx_len(8'd0),
        .tx_type(8'h20), .tx_send(1'b0), .tx_busy(), .tx_done(), .tx_fail(),
        .rx_rd_addr(b_addr), .rx_rd_data(b_data), .rx_len(b_len), .rx_type(b_type), .rx_valid(b_valid),
        .fault_inject(1'b0), .tick16_out(), .tx_seq(),
        .cnt_sent(), .cnt_recv(), .cnt_err(), .cnt_retry()
    );

    always @(negedge clk) begin
        if (ack_drop_left > 0) begin
            ack_drop_left--;
            if (ack_drop_left == 0)
                cut_ba = 0;
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (a_we && a_busy)
                $fatal(1, "Packet buffer changed while UART might retry it");
            if (a_send) begin
                if (a_busy || a_len != 128 || a_type != 8'h10 + packet_requests)
                    $fatal(1, "Invalid fragment request %0d", packet_requests);
                packet_requests++;
            end
            if ((done && previous_done) || (fail && previous_fail) || (done && fail))
                $fatal(1, "Expected mutually exclusive one-cycle result pulses");
            if ((done || fail) && busy)
                $fatal(1, "Adapter must be idle when it reports a result");
            previous_done = done;
            previous_fail = fail;

            if (b_valid) begin
                if (reading || b_len != 128 || b_type < 8'h10 || b_type > 8'h1B)
                    $fatal(1, "Invalid packet received by Board 2");
                if (b_type == 8'h10)
                    expected_fragment = 0;
                if (b_type != 8'h10 + expected_fragment)
                    $fatal(1, "Out-of-order or duplicate fragment %02h", b_type);
                read_fragment = expected_fragment;
                expected_fragment++;
                read_index = 0;
                b_addr <= 0;
                reading = 1;
                if (drop_one_ack && !ack_dropped && b_type == 8'h15) begin
                    ack_dropped = 1;
                    cut_ba = 1;
                    ack_drop_left = 45000;
                end
            end else if (reading) begin
                int byte_index;
                logic [7:0] expected_byte;
                byte_index = read_fragment * 128 + read_index;
                expected_byte = byte_index[0] ? {4'b0, ciphertext[byte_index / 2][11:8]}
                                                              : ciphertext[byte_index / 2][7:0];
                if (b_data !== expected_byte)
                    $fatal(1, "Received byte %0d: expected %02h, got %02h", byte_index, expected_byte, b_data);
                received_bytes[byte_index] = b_data;
                if (read_index == 127) begin
                    received_packets++;
                    reading = 0;
                end else begin
                    read_index++;
                    b_addr <= read_index;
                end
            end
        end
    end

    task automatic start_transfer(input bit inject_checksum, input bit lose_ack);
        received_packets = 0;
        expected_fragment = 0;
        packet_requests = 0;
        drop_one_ack = lose_ack;
        ack_dropped = 0;
        fault_inject = inject_checksum;
        start = 1;
        @(negedge clk);
        start = 0;
        fault_inject = 0;
        if (busy !== 1'b1)
            $fatal(1, "Adapter did not accept start");
        repeat (8) @(negedge clk);
        start = 1;  // Ignore another start while transmitting.
        @(negedge clk);
        start = 0;
    endtask

    task automatic finish_transfer;
        wait (done === 1'b1 || fail === 1'b1);
        @(negedge clk);
        if (fail !== 1'b0 || done !== 1'b1 || busy !== 1'b0 ||
            received_packets != 12 || packet_requests != 12)
            $fatal(1, "Expected twelve acknowledged fragments and one successful result");
        @(negedge clk);
        if (done !== 1'b0)
            $fatal(1, "Expected a one-cycle done pulse");
    endtask

    initial begin
        logic [11:0] retries_before;
        $readmemh("crypto/test_vectors/ciphertext/u0.mem", ciphertext,   0, 255);
        $readmemh("crypto/test_vectors/ciphertext/u1.mem", ciphertext, 256, 511);
        $readmemh("crypto/test_vectors/ciphertext/v.mem",  ciphertext, 512, 767);
        for (int i = 0; i < 768; i++)
            if ($isunknown(ciphertext[i]))
                $fatal(1, "Missing Python ciphertext fixture");
        repeat (10) @(negedge clk);
        rst = 0;

        start_transfer(0, 0);
        finish_transfer();
        $display("PASS: all 1536 Python ciphertext bytes delivered in twelve UART packets");

        retries_before = a_retries;
        start_transfer(1, 0);
        finish_transfer();
        if (a_retries == retries_before)
            $fatal(1, "Checksum fault did not exercise a UART retry");
        $display("PASS: checksum failure retries the unchanged packet and completes the ciphertext");

        retries_before = a_retries;
        start_transfer(0, 1);
        finish_transfer();
        if (!ack_dropped || a_retries == retries_before)
            $fatal(1, "Lost acknowledgement did not exercise a UART retry");
        $display("PASS: a lost acknowledgement is retried without duplicate fragment delivery");

        start_transfer(0, 0);
        wait (received_packets == 4);
        @(negedge clk);
        cut_ab = 1;
        wait (fail === 1'b1 || done === 1'b1);
        @(negedge clk);
        if (fail !== 1'b1 || done !== 1'b0 || busy !== 1'b0 || received_packets != 4)
            $fatal(1, "Expected a terminal failure after a partial ciphertext");
        repeat (20) @(negedge clk);
        if (a_we || a_send || done || fail)
            $fatal(1, "Adapter continued sending after a terminal failure");
        cut_ab = 0;
        $display("PASS: terminal UART failure stops the adapter after a partial ciphertext");

        start_transfer(0, 0);
        finish_transfer();
        $display("PASS: a new start after failure resends the complete ciphertext from fragment zero");
        if ($test$plusargs("capture_uart"))
            $writememh("uart_ciphertext_bytes.mem", received_bytes);
        $finish;
    end

    initial begin
        #150000000;
        $fatal(1, "Ciphertext UART simulation timed out");
    end
endmodule
