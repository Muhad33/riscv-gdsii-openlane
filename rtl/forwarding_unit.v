`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// forwarding_unit: selects the newest value of rs1 / rs2 for the EX stage.
//
// Priority (newest first):
//   2'b10 - from EX/MEM (result of the instruction one ahead)
//   2'b01 - from MEM/WB (write-back value of the instruction two ahead)
//   2'b00 - from ID/EX  (value read from the register file)
// A source is only used if that instruction writes a register other than x0.
// (A load in EX/MEM is never needed here: the hazard unit stalls load-use pairs.)
//
// Ports:
//   id_ex_rs1, id_ex_rs2           - source registers of the instruction in EX
//   ex_mem_rd, ex_mem_reg_write    - destination of the instruction in MEM
//   mem_wb_rd, mem_wb_reg_write    - destination of the instruction in WB
//   forward_a, forward_b           - mux selects for operand rs1 / rs2
// -----------------------------------------------------------------------------
module forwarding_unit (
    input  wire [4:0] id_ex_rs1,
    input  wire [4:0] id_ex_rs2,
    input  wire [4:0] ex_mem_rd,
    input  wire       ex_mem_reg_write,
    input  wire [4:0] mem_wb_rd,
    input  wire       mem_wb_reg_write,
    output reg  [1:0] forward_a,
    output reg  [1:0] forward_b
);

    wire ex_mem_ok = ex_mem_reg_write && (ex_mem_rd != 5'd0);
    wire mem_wb_ok = mem_wb_reg_write && (mem_wb_rd != 5'd0);

    always @(*) begin
        if (ex_mem_ok && ex_mem_rd == id_ex_rs1)      forward_a = 2'b10;
        else if (mem_wb_ok && mem_wb_rd == id_ex_rs1) forward_a = 2'b01;
        else                                          forward_a = 2'b00;

        if (ex_mem_ok && ex_mem_rd == id_ex_rs2)      forward_b = 2'b10;
        else if (mem_wb_ok && mem_wb_rd == id_ex_rs2) forward_b = 2'b01;
        else                                          forward_b = 2'b00;
    end

endmodule
