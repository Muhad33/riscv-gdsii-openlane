`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_core_with_mem: riscv_core + behavioral instruction ROM and data RAM.
//
// The memories reproduce the original on-chip memories of ref/cpu_top.v
// exactly, so results (and cycle counts) must match the reference design:
//   - instruction ROM: 1024 words at 0x0, combinational read, mirrored above
//     4 KiB, unused words = NOP
//   - data RAM: 1024 words at 0x0001_0000, combinational read, byte-enable
//     write on the rising edge; outside the range writes are ignored and reads
//     return 0
//
// Runs one program until 'halted' or a watchdog expires, then dumps the
// architectural state for scripts/run_tests.py to compare with the Python
// golden model.
//
// Defines:
//   GATE_LEVEL  - DUT is the post-layout netlist: no hierarchical references
//                 into the core. Registers are rebuilt from the retire port and
//                 the commit trace has no PC (written as 00000000).
// Plusargs:
//   +HEX=<file>     instruction ROM image (required)
//   +DHEX=<file>    data RAM image (optional, .data section)
//   +OUT=<prefix>   output prefix (default sim/core)
//   +MAXCYC=<n>     watchdog in cycles (default 200000)
//   +VCD            write <prefix>.vcd
// Outputs (<prefix>_*): _regs.txt, _mem.txt, _commit.txt ("pc rd value"),
// _stats.txt (cycles, instret, halted). Prints "HALTED ..." or "TIMEOUT ...".
// -----------------------------------------------------------------------------
module tb_core_with_mem;

    localparam IMEM_WORDS = 1024;
    localparam DMEM_WORDS = 1024;
    localparam [31:0] DMEM_BASE = 32'h0001_0000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;  // 10 ns period in simulation (functional check only)

    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [31:0] imem_rdata, dmem_rdata;
    wire        dmem_re, dmem_we, halted;
    wire [3:0]  dmem_be;
    wire        retire_valid, retire_we;
    wire [4:0]  retire_rd;
    wire [31:0] retire_wdata;

    riscv_core dut (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_we(dmem_we), .dmem_be(dmem_be),
        .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .halted(halted),
        .retire_valid(retire_valid), .retire_we(retire_we), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata)
    );

    // ---------------------------------------------------------------- memories
    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];

    assign imem_rdata = imem[imem_addr[11:2]];

    wire       d_in_range = (dmem_addr[31:12] == DMEM_BASE[31:12]);
    wire [9:0] d_idx      = dmem_addr[11:2];
    assign dmem_rdata = d_in_range ? dmem[d_idx] : 32'd0;

    always @(posedge clk) begin
        if (dmem_we && d_in_range) begin
            if (dmem_be[0]) dmem[d_idx][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) dmem[d_idx][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) dmem[d_idx][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) dmem[d_idx][31:24] <= dmem_wdata[31:24];
        end
    end

    // ---------------------------------------------------------------- counters / shadow state
    integer cycles, instret;
    reg [31:0] shadow_regs [0:31];  // rebuilt from the retire port
    reg [31:0] wb_pc;               // PC of the instruction in WB (RTL only)

`ifndef GATE_LEVEL
    // EX/MEM and MEM/WB never hold, so the WB-stage PC is the EX-stage PC two edges ago
    reg [31:0] mem_pc;
    always @(posedge clk) begin
        mem_pc <= dut.id_ex_valid ? dut.id_ex_pc : 32'd0;
        wb_pc  <= mem_pc;
    end
`else
    initial wb_pc = 32'd0;
`endif

    integer fd_commit, fd, i, maxcyc, n;
    reg [8*256-1:0] hexfile, dhexfile, prefix;

    // X-propagation check: every core output must be 0/1 once reset has been applied
    always @(posedge clk) begin
        if (!rst && ^{imem_addr, dmem_addr, dmem_re, dmem_we, dmem_be, dmem_wdata, halted,
                      retire_valid, retire_we, retire_rd, retire_wdata} === 1'bx)
            $display("ERROR: X on a core output at cycle %0d", cycles);
    end

    always @(posedge clk) begin
        if (rst) begin
            cycles  <= 0;
            instret <= 0;
        end else if (!halted) begin
            cycles <= cycles + 1;
            if (retire_valid)
                instret <= instret + 1;
            if (retire_we && retire_rd != 5'd0) begin
                shadow_regs[retire_rd] <= retire_wdata;
                $fdisplay(fd_commit, "%08x %0d %08x", wb_pc, retire_rd, retire_wdata);
            end
        end
    end

    // ---------------------------------------------------------------- main
    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h0000_0013;  // NOP
        for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1) shadow_regs[i] = 32'd0;

        if (!$value$plusargs("HEX=%s", hexfile)) begin
            $display("ERROR: missing +HEX=<file>");
            $finish;
        end
        if (!$value$plusargs("OUT=%s", prefix)) prefix = "sim/core";
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 200000;
        if ($test$plusargs("VCD")) begin
            $dumpfile({prefix, ".vcd"});
            $dumpvars(0, tb_core_with_mem);
        end
        $readmemh(hexfile, imem);
        if ($value$plusargs("DHEX=%s", dhexfile))
            $readmemh(dhexfile, dmem);

        fd_commit = $fopen({prefix, "_commit.txt"}, "w");

        repeat (3) @(posedge clk);
        rst <= 1'b0;

        n = 0;
        while (!halted && n < maxcyc) begin
            @(posedge clk);
            n = n + 1;
        end
        @(posedge clk);
        #1;

        fd = $fopen({prefix, "_regs.txt"}, "w");
        $fdisplay(fd, "%08x", 32'd0);
        for (i = 1; i < 32; i = i + 1) begin
`ifndef GATE_LEVEL
            if (dut.u_rf.regs[i] !== shadow_regs[i])
                $display("ERROR: x%0d regfile %08x != retire-port shadow %08x", i, dut.u_rf.regs[i], shadow_regs[i]);
            $fdisplay(fd, "%08x", dut.u_rf.regs[i]);
`else
            $fdisplay(fd, "%08x", shadow_regs[i]);
`endif
        end
        $fclose(fd);
        fd = $fopen({prefix, "_mem.txt"}, "w");
        for (i = 0; i < DMEM_WORDS; i = i + 1)
            $fdisplay(fd, "%08x", dmem[i]);
        $fclose(fd);
        fd = $fopen({prefix, "_stats.txt"}, "w");
        $fdisplay(fd, "cycles %0d", cycles);
        $fdisplay(fd, "instret %0d", instret);
        $fdisplay(fd, "halted %0d", halted);
        $fclose(fd);
        $fclose(fd_commit);

        if (halted === 1'b1)
            $display("HALTED after %0d cycles, %0d instructions, CPI = %0.3f",
                     cycles, instret, 1.0 * cycles / instret);
        else
            $display("TIMEOUT: no halt within %0d cycles (watchdog)", maxcyc);
        $finish;
    end

endmodule
