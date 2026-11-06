`timescale 1ns / 1ps

// Five registered stages, accepting a new pair every clock. For canonical
// operands (0..3328), r is a*b mod 3329. Consumers sample r five clocks after
// presenting a/b; the transform FSMs hold their operands through that interval.
// No reset is needed: consumers discard pipeline contents after reset/start.
module mod_mult_pipeline (
    input wire clk,
    input wire [11:0] a, b,
    output reg [11:0] r
);
    reg [11:0] a_q, b_q;
    reg [23:0] product, product_q;
    reg [12:0] quotient, residue;
    wire [36:0] scaled = product * 13'd5039;
    // The true residual is in 0..2*q-1, so its low 13 bits are sufficient.
    wire [12:0] correction = quotient * 12'd3329;

    always @(posedge clk) begin
        a_q <= a;
        b_q <= b;
        product <= a_q * b_q;
        product_q <= product;
        quotient <= scaled[36:24];
        residue <= product_q[12:0] - correction;
        r <= (residue >= 13'd3329) ? residue - 13'd3329 : residue;
    end
endmodule
