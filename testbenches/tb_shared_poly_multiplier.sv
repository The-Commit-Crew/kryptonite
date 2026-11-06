`timescale 1ns / 1ps

// Independent schoolbook negacyclic oracle, including wraparound, dense inputs,
// repeated starts, synchronous readback, ignored busy requests and reset aborts.
module tb_shared_poly_multiplier;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1, wr_en = 0, start = 0;
    logic [7:0] wr_addr = 0, rd_addr = 0;
    logic [11:0] left_data = 0, right_data = 0;
    wire done, reference_done;
    wire [11:0] rd_data, reference_data;
    int seed = 32'h20263329;
    int completed = 0;
    logic oracle_enable = 1;

    shared_poly_multiplier dut (.*);
    poly_mult_model reference (
        .clk(clk), .rst(rst), .wr_en(wr_en && oracle_enable), .wr_addr(wr_addr),
        .left_data(left_data), .right_data(right_data), .start(start && oracle_enable),
        .done(reference_done), .rd_addr(rd_addr), .rd_data(reference_data)
    );

    task automatic load_and_start(input int pattern);
        oracle_enable = 1;
        for (int i = 0; i < 256; i++) begin
            wr_en = 1;
            wr_addr = i;
            case (pattern)
                0: begin left_data = 0; right_data = $urandom(seed) % 3329; end
                1: begin left_data = (i == 0); right_data = $urandom(seed) % 3329; end
                2: begin left_data = (i == 255); right_data = (i == 1); end
                3: begin left_data = 3328; right_data = 3328; end
                default: begin
                    left_data = $urandom(seed) % 3329;
                    right_data = $urandom(seed) % 3329;
                end
            endcase
            @(negedge clk);
        end
        wr_en = 0;
        start = 1;
        @(negedge clk);
        start = 0;
        oracle_enable = 0;
    endtask

    task automatic check_product(input int pattern);
        int cycles;
        cycles = 0;
        // Requests during an active operation must not alter its operands.
        // The oracle computes immediately on the original start.
        repeat (10) @(negedge clk);
        wr_en = 1;
        wr_addr = 42;
        left_data = 123;
        right_data = 456;
        start = 1;
        @(negedge clk);
        wr_en = 0;
        start = 0;
        while (!done && cycles < 40000) begin
            @(negedge clk);
            cycles++;
        end
        if (done !== 1'b1)
            $fatal(1, "Multiplier timed out on pattern %0d", pattern);
        completed++;
        for (int i = 0; i < 256; i++) begin
            // Odd stride visits every address and exercises nonsequential reads.
            rd_addr = (i * 73 + 19) % 256;
            @(posedge clk);
            #1;
            if ($isunknown(rd_data) || rd_data >= 3329 || rd_data !== reference_data)
                $fatal(1, "Pattern %0d coefficient %0d: expected %0d, got %0d",
                       pattern, rd_addr, reference_data, rd_data);
            if (done !== 1'b0)
                $fatal(1, "done must pulse for exactly one clock");
            @(negedge clk);
        end
        repeat (5) @(negedge clk);
        if (rd_data !== reference_data || done !== 1'b0)
            $fatal(1, "Result was not retained while idle");
        $display("PASS: polynomial pattern %0d matched all 256 oracle coefficients", pattern);
    endtask

    task automatic abort_operation(input bit inverse_phase);
        load_and_start(4);
        if (inverse_phase)
            wait (dut.state == dut.INTT_WAIT);
        repeat (100) @(negedge clk);
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (8) begin
            @(negedge clk);
            if (done !== 1'b0)
                $fatal(1, "Aborted operation produced done");
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        for (int pattern = 0; pattern < 8; pattern++) begin
            load_and_start(pattern);
            check_product(pattern);
        end
        abort_operation(0);
        load_and_start(4);
        check_product(4);
        abort_operation(1);
        load_and_start(5);
        check_product(5);
        $display("PASS: %0d polynomial products, busy protection and reset recovery", completed);
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "Polynomial multiplier regression timed out");
    end
endmodule
