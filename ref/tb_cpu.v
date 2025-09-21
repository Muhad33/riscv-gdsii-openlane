`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_cpu: runs one program on cpu_top until it halts (ECALL/EBREAK) or a
// watchdog expires, then dumps the architectural state for comparison with the
// Python golden model.
//
// Plusargs:
//   +HEX=<file>     instruction ROM image (required)
//   +DHEX=<file>    data RAM image (optional, .data section)
//   +OUT=<prefix>   output prefix (default sim/cpu)
//   +MAXCYC=<n>     watchdog in cycles (default 200000)
//   +NOVCD          do not write a VCD file
//
// Outputs (<prefix>_*):
//   _regs.txt    final x0..x31, one hex word per line
//   _mem.txt     final data RAM, one hex word per line
//   _commit.txt  register-write trace "pc rd value" (from the WB stage)
//   _pipe.txt    per-cycle pipeline occupancy (instruction ids per stage, stall/flush)
//   _stats.txt   cycles, instructions, CPI, halted flag
//   .vcd         waveform
// The testbench prints "HALTED ..." or "TIMEOUT ..." (run_tests.py checks it).
// -----------------------------------------------------------------------------
module tb_cpu;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;  // 100 MHz

    wire        halted;
    wire [31:0] cycle_count, instret_count;

    cpu_top dut (.clk(clk), .rst(rst), .halted(halted), .cycle_count(cycle_count), .instret_count(instret_count));

    reg [8*256-1:0] hexfile, dhexfile, prefix;
    integer maxcyc, fd_commit, fd_pipe, fd, i, cycles;

    // ---------------------------------------------------------------- shadow pipeline (for the pipeline diagram)
    // Each fetched instruction gets an id; the ids follow the same stall/flush rules as the RTL.
    integer fetch_id, next_id, sh_ifid, sh_idex, sh_exmem, sh_memwb;

    initial begin
        if (!$value$plusargs("HEX=%s", hexfile)) begin
            $display("ERROR: missing +HEX=<file>");
            $finish;
        end
        if (!$value$plusargs("OUT=%s", prefix)) prefix = "sim/cpu";
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 200000;
        if (!$test$plusargs("NOVCD")) begin
            $dumpfile({prefix, ".vcd"});
            $dumpvars(0, tb_cpu);
        end

        #1;  // after the memories' own initial blocks
        $readmemh(hexfile, dut.u_imem.mem);
        if ($value$plusargs("DHEX=%s", dhexfile))
            $readmemh(dhexfile, dut.u_dmem.mem);

        fd_commit = $fopen({prefix, "_commit.txt"}, "w");
        fd_pipe   = $fopen({prefix, "_pipe.txt"}, "w");
        $fdisplay(fd_pipe, "# cycle if_id if_pc id_id ex_id mem_id wb_id stall flush");

        repeat (3) @(posedge clk);
        rst <= 1'b0;

        cycles = 0;
        while (!halted && cycles < maxcyc) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);  // let the last commit be logged

        // ---------------- dump architectural state
        fd = $fopen({prefix, "_regs.txt"}, "w");
        $fdisplay(fd, "%08x", 32'd0);
        for (i = 1; i < 32; i = i + 1)
            $fdisplay(fd, "%08x", dut.u_rf.regs[i]);
        $fclose(fd);
        fd = $fopen({prefix, "_mem.txt"}, "w");
        for (i = 0; i < 1024; i = i + 1)
            $fdisplay(fd, "%08x", dut.u_dmem.mem[i]);
        $fclose(fd);
        fd = $fopen({prefix, "_stats.txt"}, "w");
        $fdisplay(fd, "cycles %0d", cycle_count);
        $fdisplay(fd, "instret %0d", instret_count);
        $fdisplay(fd, "halted %0d", halted);
        $fclose(fd);
        $fclose(fd_commit);
        $fclose(fd_pipe);

        if (halted)
            $display("HALTED after %0d cycles, %0d instructions, CPI = %0.3f",
                     cycle_count, instret_count, 1.0 * cycle_count / instret_count);
        else
            $display("TIMEOUT: no halt within %0d cycles (watchdog)", maxcyc);
        $finish;
    end

    // ---------------------------------------------------------------- commit trace (WB stage)
    // Sampled at the clock edge: these are the values being written at this edge.
    always @(posedge clk) begin
        if (!rst && !halted && dut.wb_we && dut.wb_rd != 5'd0)
            $fdisplay(fd_commit, "%08x %0d %08x", dut.mem_wb_pc, dut.wb_rd, dut.wb_data);
    end

    // ---------------------------------------------------------------- pipeline occupancy trace
    always @(posedge clk) begin
        if (rst) begin
            fetch_id = 0; next_id = 1;
            sh_ifid = -1; sh_idex = -1; sh_exmem = -1; sh_memwb = -1;
        end else if (!halted) begin
            $fdisplay(fd_pipe, "%0d %0d %08x %0d %0d %0d %0d %0d %0d", cycle_count, fetch_id, dut.pc,
                      sh_ifid, sh_idex, sh_exmem, sh_memwb, dut.stall, dut.if_id_flush & ~dut.halting);
            // advance exactly like the RTL pipeline registers (values sampled before this edge)
            sh_memwb = sh_exmem;
            sh_exmem = sh_idex;
            sh_idex  = (dut.id_ex_flush || !dut.if_id_valid) ? -1 : sh_ifid;
            if (dut.if_id_flush)   sh_ifid = -1;
            else if (!dut.if_id_hold) sh_ifid = fetch_id;
            if (dut.pc_sel != 2'b01) begin  // PC moves: a new instruction is fetched
                fetch_id = next_id;
                next_id  = next_id + 1;
            end
        end
    end

endmodule
