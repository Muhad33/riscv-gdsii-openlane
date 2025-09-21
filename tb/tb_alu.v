`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_alu: self-checking ALU test. Directed edge cases plus 2000 random vectors per
// operation, compared against a behavioral reference. Prints PASS or FAIL.
// -----------------------------------------------------------------------------
module tb_alu;

    reg  [31:0] a, b;
    reg  [3:0]  op;
    wire [31:0] y;
    integer errors = 0, checks = 0, i, k;
    integer seed = 32'h00A1_0000;

    alu dut (.a(a), .b(b), .alu_ctrl(op), .result(y));

    function [31:0] ref_alu;
        input [31:0] x, z;
        input [3:0]  o;
        begin
            case (o)
                4'd0: ref_alu = x + z;
                4'd1: ref_alu = x - z;
                4'd2: ref_alu = x << z[4:0];
                4'd3: ref_alu = ($signed(x) < $signed(z)) ? 32'd1 : 32'd0;
                4'd4: ref_alu = (x < z) ? 32'd1 : 32'd0;
                4'd5: ref_alu = x ^ z;
                4'd6: ref_alu = x >> z[4:0];
                4'd7: ref_alu = $unsigned($signed(x) >>> z[4:0]);
                4'd8: ref_alu = x | z;
                4'd9: ref_alu = x & z;
                default: ref_alu = 32'd0;
            endcase
        end
    endfunction

    task check;
        input [31:0] x, z;
        input [3:0]  o;
        input [31:0] expected;  // pass ref_alu(...) or a hand-written value
        begin
            a = x; b = z; op = o;
            #1;
            checks = checks + 1;
            if (y !== expected) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("ERROR: op %0d a=%08x b=%08x -> %08x, expected %08x", o, x, z, y, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_alu.vcd");
        $dumpvars(0, tb_alu);

        // directed edge cases (hand-computed expected values)
        check(32'h7fffffff, 32'h00000001, 4'd0, 32'h80000000);  // ADD overflow
        check(32'h80000000, 32'h00000001, 4'd1, 32'h7fffffff);  // SUB underflow
        check(32'h00000000, 32'h00000001, 4'd1, 32'hffffffff);  // 0 - 1
        check(32'h80000001, 32'h00000000, 4'd2, 32'h80000001);  // SLL by 0
        check(32'h00000001, 32'h0000001f, 4'd2, 32'h80000000);  // SLL by 31
        check(32'h00000001, 32'h00000020, 4'd2, 32'h00000001);  // SLL uses only 5 bits (32 -> 0)
        check(32'h80000000, 32'h7fffffff, 4'd3, 32'h00000001);  // SLT signed
        check(32'h80000000, 32'h7fffffff, 4'd4, 32'h00000000);  // SLTU unsigned
        check(32'hfffffff9, 32'h00000005, 4'd3, 32'h00000001);  // -7 < 5
        check(32'h00000005, 32'h00000005, 4'd3, 32'h00000000);  // equal
        check(32'h80000000, 32'h0000001f, 4'd6, 32'h00000001);  // SRL by 31
        check(32'h80000000, 32'h0000001f, 4'd7, 32'hffffffff);  // SRA by 31
        check(32'h80000000, 32'h00000000, 4'd7, 32'h80000000);  // SRA by 0
        check(32'h7fffffff, 32'h0000001f, 4'd7, 32'h00000000);  // SRA positive
        check(32'h0ff00ff0, 32'h00ffff00, 4'd5, 32'h0f0ff0f0);  // XOR
        check(32'h0ff00ff0, 32'h00ffff00, 4'd8, 32'h0ffffff0);  // OR
        check(32'h0ff00ff0, 32'h00ffff00, 4'd9, 32'h00f00f00);  // AND

        // random vectors for every operation
        for (k = 0; k <= 9; k = k + 1) begin
            for (i = 0; i < 2000; i = i + 1) begin
                a = $random(seed);
                b = $random(seed);
                check(a, b, k[3:0], ref_alu(a, b, k[3:0]));
            end
        end

        if (errors == 0)
            $display("PASS: tb_alu (%0d checks)", checks);
        else
            $display("FAIL: tb_alu (%0d errors in %0d checks)", errors, checks);
        $finish;
    end

endmodule
