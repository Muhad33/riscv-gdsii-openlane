`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_regfile: self-checking register file test.
//   - x0 reads 0 and ignores writes
//   - write-before-read bypass (same-cycle write is visible on the read ports)
//   - 5000 random write/read cycles against a reference array
// Stimulus changes right after the falling edge, checks happen before the rising
// edge, so there are no races with the clocked write. Prints PASS or FAIL.
// -----------------------------------------------------------------------------
module tb_regfile;

    reg         clk = 1'b0, rst = 1'b1, we = 1'b0;
    reg  [4:0]  ra1 = 0, ra2 = 0, wa = 0;
    reg  [31:0] wd = 0;
    wire [31:0] rd1, rd2;
    reg  [31:0] model [0:31];
    integer errors = 0, checks = 0, i;
    integer seed = 32'h0000_BEEF;

    always #5 clk = ~clk;

    regfile dut (.clk(clk), .rst(rst), .raddr1(ra1), .raddr2(ra2), .rdata1(rd1), .rdata2(rd2),
                 .we(we), .waddr(wa), .wdata(wd));

    task expect_eq;
        input [31:0] got, exp;
        input [8*24-1:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 10) $display("ERROR: %0s got %08x expected %08x", what, got, exp);
            end
        end
    endtask

    // expected read value including the same-cycle bypass
    function [31:0] expected_read;
        input [4:0] r;
        begin
            if (r == 0)                expected_read = 32'd0;
            else if (we && wa == r)    expected_read = wd;
            else                       expected_read = model[r];
        end
    endfunction

    initial begin
        $dumpfile("sim/tb_regfile.vcd");
        $dumpvars(0, tb_regfile);
        for (i = 0; i < 32; i = i + 1) model[i] = 0;
        @(negedge clk); @(negedge clk);
        rst = 1'b0;

        // x0: write is ignored
        we = 1; wa = 0; wd = 32'hdeadbeef; ra1 = 0;
        #1 expect_eq(rd1, 32'd0, "x0 during write");
        @(negedge clk);
        we = 0;
        #1 expect_eq(rd1, 32'd0, "x0 after write");

        // write-before-read: data visible in the same cycle
        we = 1; wa = 5; wd = 32'h12345678; ra1 = 5; ra2 = 5;
        #1 expect_eq(rd1, 32'h12345678, "bypass port 1");
        expect_eq(rd2, 32'h12345678, "bypass port 2");
        @(negedge clk);
        model[5] = 32'h12345678;
        we = 0;
        #1 expect_eq(rd1, 32'h12345678, "stored value");

        // random traffic
        for (i = 0; i < 5000; i = i + 1) begin
            @(negedge clk);
            we  = $random(seed);
            wa  = $random(seed);
            wd  = $random(seed);
            ra1 = $random(seed);
            ra2 = (i % 4 == 0) ? wa : $random(seed);  // frequent same-register reads
            #1;
            expect_eq(rd1, expected_read(ra1), "random port 1");
            expect_eq(rd2, expected_read(ra2), "random port 2");
            @(posedge clk);
            #1 if (we && wa != 0) model[wa] = wd;
        end

        if (errors == 0)
            $display("PASS: tb_regfile (%0d checks)", checks);
        else
            $display("FAIL: tb_regfile (%0d errors in %0d checks)", errors, checks);
        $finish;
    end

endmodule
