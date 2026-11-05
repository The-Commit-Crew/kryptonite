`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// kbd_decode.v (Anannya) - PS/2 scan code set 2 -> ASCII, with Shift
//  F0 = next code is a key RELEASE, E0/E1 = extended key (ignored)
//  letters: lower case, upper case while Shift is held
//  also: 0-9  space  -  .  and Shift+1 = !  Shift+. = >  Shift+; = :
//  control outputs: Enter 0D, Backspace 08, Esc 1B, Tab 09
//  anything else (including power-on codes AA / FA) is ignored
//////////////////////////////////////////////////////////////////////////////
module kbd_decode (
    input  clk,
    input  rst,
    input  [7:0] code,
    input  code_valid,
    output reg [7:0] key       = 8'd0,
    output reg       key_valid = 1'b0
);
    reg brk   = 1'b0;
    reg ext   = 1'b0;
    reg shift = 1'b0;

    function [7:0] lookup;
        input [7:0] c;
        input       sh;
        reg [7:0] u;
        begin
            u = 8'h00;
            case (c)                                   // letters: upper-case ASCII
                8'h1C: u = "A";  8'h32: u = "B";  8'h21: u = "C";  8'h23: u = "D";
                8'h24: u = "E";  8'h2B: u = "F";  8'h34: u = "G";  8'h33: u = "H";
                8'h43: u = "I";  8'h3B: u = "J";  8'h42: u = "K";  8'h4B: u = "L";
                8'h3A: u = "M";  8'h31: u = "N";  8'h44: u = "O";  8'h4D: u = "P";
                8'h15: u = "Q";  8'h2D: u = "R";  8'h1B: u = "S";  8'h2C: u = "T";
                8'h3C: u = "U";  8'h2A: u = "V";  8'h1D: u = "W";  8'h22: u = "X";
                8'h35: u = "Y";  8'h1A: u = "Z";
                default: u = 8'h00;
            endcase
            if (u != 8'h00)
                lookup = sh ? u : (u + 8'h20);
            else begin
                case (c)
                    8'h45: lookup = sh ? 8'h00 : "0";
                    8'h16: lookup = sh ? "!"   : "1";
                    8'h1E: lookup = sh ? 8'h00 : "2";
                    8'h26: lookup = sh ? 8'h00 : "3";
                    8'h25: lookup = sh ? 8'h00 : "4";
                    8'h2E: lookup = sh ? 8'h00 : "5";
                    8'h36: lookup = sh ? 8'h00 : "6";
                    8'h3D: lookup = sh ? 8'h00 : "7";
                    8'h3E: lookup = sh ? 8'h00 : "8";
                    8'h46: lookup = sh ? 8'h00 : "9";
                    8'h4E: lookup = sh ? 8'h00 : "-";
                    8'h49: lookup = sh ? ">"   : ".";
                    8'h4C: lookup = sh ? ":"   : 8'h00;
                    8'h29: lookup = " ";
                    8'h5A: lookup = 8'h0D;             // Enter
                    8'h66: lookup = 8'h08;             // Backspace
                    8'h76: lookup = 8'h1B;             // Esc
                    8'h0D: lookup = 8'h09;             // Tab
                    default: lookup = 8'h00;
                endcase
            end
        end
    endfunction

    wire [7:0] lk = lookup(code, shift);

    always @(posedge clk) begin
        key_valid <= 1'b0;
        if (rst) begin
            brk <= 1'b0; ext <= 1'b0; shift <= 1'b0; key <= 8'd0;
        end else if (code_valid) begin
            if (code == 8'hF0)
                brk <= 1'b1;
            else if (code == 8'hE0 || code == 8'hE1)
                ext <= 1'b1;
            else begin
                brk <= 1'b0;
                ext <= 1'b0;
                if (!ext && (code == 8'h12 || code == 8'h59))
                    shift <= !brk;                     // left / right Shift down or up
                else if (!brk && !ext && lk != 8'h00) begin
                    key       <= lk;
                    key_valid <= 1'b1;
                end
            end
        end
    end
endmodule