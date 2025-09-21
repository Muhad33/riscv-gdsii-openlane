`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// instr_mem: instruction ROM, word-organized, asynchronous read.
//
// Contents come from a hex file (one 32-bit word per line) via $readmemh, either
// through the MEM_FILE parameter or by the testbench writing u_imem.mem directly.
// Unused words read as NOP (addi x0, x0, 0). Address bits above the ROM size are
// ignored (the ROM is mirrored); programs live at 0x0000_0000.
//
// Parameters:
//   WORDS    - number of 32-bit words (default 1024 = 4 KiB)
//   MEM_FILE - optional hex file to preload
// Ports:
//   addr  - byte address (PC); bits [1:0] are ignored
//   instr - instruction word
// -----------------------------------------------------------------------------
module instr_mem #(
    parameter WORDS    = 1024,
    parameter MEM_FILE = ""
) (
    input  wire [31:0] addr,
    output wire [31:0] instr
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam AW = clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];
    integer i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'h0000_0013;  // NOP
        if (MEM_FILE != "")
            $readmemh(MEM_FILE, mem);
    end

    assign instr = mem[addr[AW+1:2]];

endmodule
