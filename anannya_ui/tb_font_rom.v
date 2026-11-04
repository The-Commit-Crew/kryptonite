`timescale 1ns / 1ps
module tb_font_rom;
    reg  [7:0] ascii = 8'h20;
    reg  [2:0] row   = 3'd0;
    wire [4:0] bits;
    integer errors = 0;
    integer c;                         // outer-loop counter (tasks have their own)

    font_rom dut (.ascii(ascii), .row(row), .bits(bits));

    task row_is;                       // one row of one character must match
        input [7:0] a;
        input [2:0] rw;
        input [4:0] want;
        begin
            ascii = a; row = rw; #1;
            if (bits !== want) begin
                errors = errors + 1;
                $display("FAIL: char %h row %0d = %b, want %b", a, rw, bits, want);
            end
        end
    endtask

    task nonblank;                     // at least one lit pixel somewhere
        input [7:0] a;
        integer i;
        reg any;
        begin
            any = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ascii = a; row = i[2:0]; #1;
                if (bits !== 5'b00000) any = 1;
            end
            if (!any) begin errors = errors + 1; $display("FAIL: char %h is blank", a); end
        end
    endtask

    task blank;                        // no lit pixel anywhere
        input [7:0] a;
        integer i;
        reg any;
        begin
            any = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ascii = a; row = i[2:0]; #1;
                if (bits !== 5'b00000) any = 1;
            end
            if (any) begin errors = errors + 1; $display("FAIL: char %h should be blank", a); end
        end
    endtask

    initial begin
        #1;
        // ---- new letters ----
        row_is(8'h4E, 0, 5'b10001); row_is(8'h4E, 2, 5'b11001);   // N
        row_is(8'h4E, 4, 5'b10011); row_is(8'h4E, 6, 5'b10001);
        row_is(8'h48, 0, 5'b10001); row_is(8'h48, 3, 5'b11111);   // H
        row_is(8'h4A, 0, 5'b00111); row_is(8'h4A, 5, 5'b10010);   // J
        row_is(8'h4A, 6, 5'b01100);
        row_is(8'h51, 4, 5'b10101); row_is(8'h51, 6, 5'b01101);   // Q
        row_is(8'h56, 0, 5'b10001); row_is(8'h56, 5, 5'b01010);   // V
        row_is(8'h56, 6, 5'b00100);
        row_is(8'h58, 0, 5'b10001); row_is(8'h58, 3, 5'b00100);   // X
        row_is(8'h58, 6, 5'b10001);
        row_is(8'h5A, 0, 5'b11111); row_is(8'h5A, 3, 5'b00100);   // Z
        row_is(8'h5A, 6, 5'b11111);
        // ---- new symbols ----
        row_is(8'h2D, 2, 5'b00000); row_is(8'h2D, 3, 5'b11111);   // -
        row_is(8'h21, 0, 5'b00100); row_is(8'h21, 5, 5'b00000);   // !
        row_is(8'h21, 6, 5'b00100);
        row_is(8'h2E, 0, 5'b00000); row_is(8'h2E, 5, 5'b01100);   // .
        row_is(8'h2E, 6, 5'b01100);
        row_is(8'h3E, 0, 5'b01000); row_is(8'h3E, 3, 5'b00001);   // >
        row_is(8'h3E, 6, 5'b01000);
        // ---- old glyphs unchanged ----
        row_is(8'h30, 0, 5'b01110);                               // 0
        row_is(8'h37, 0, 5'b11111);                               // 7
        row_is(8'h41, 3, 5'b11111);                               // A
        row_is(8'h45, 0, 5'b11111);                               // E
        row_is(8'h4D, 1, 5'b11011);                               // M
        row_is(8'h53, 0, 5'b01111);                               // S
        row_is(8'h59, 6, 5'b00100);                               // Y
        row_is(8'h3A, 1, 5'b00100);                               // :
        // ---- everything we draw is non-blank ----
        for (c = 8'h30; c <= 8'h39; c = c + 1) nonblank(c[7:0]);  // 0-9
        for (c = 8'h41; c <= 8'h5A; c = c + 1) nonblank(c[7:0]);  // A-Z
        nonblank(8'h2D); nonblank(8'h21); nonblank(8'h2E); nonblank(8'h3E);
        // ---- unsupported characters stay blank ----
        blank(8'h20); blank(8'h61); blank(8'h40); blank(8'h7E); blank(8'h00);

        if (errors == 0) $display("PASS: tb_font_rom");
        else             $display("FAIL: tb_font_rom, %0d errors", errors);
        $finish;
    end
endmodule