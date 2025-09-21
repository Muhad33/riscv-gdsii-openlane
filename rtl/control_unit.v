`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// control_unit: main decoder. Turns opcode / funct3 / funct7 into the control
// signals carried down the pipeline (purely combinational).
//
// Unsupported instructions:
//   FENCE (MISC-MEM)          -> NOP
//   CSR instructions (SYSTEM, funct3 != 0) -> NOP
//   ECALL / EBREAK            -> is_halt = 1 (ends the program, see cpu_top)
//   any unknown opcode        -> NOP
//
// Ports:
//   instr     - instruction in the ID stage
//   reg_write - writes rd
//   alu_src_a - ALU operand A: 0 = rs1, 1 = PC, 2 = zero
//   alu_src_b - ALU operand B: 0 = rs2, 1 = immediate
//   alu_ctrl  - ALU operation (encoding as in alu.v)
//   mem_read  - load
//   mem_write - store
//   wb_sel    - write-back source: 0 = EX result, 1 = load data
//   branch    - conditional branch (condition from funct3)
//   jal, jalr - jumps (rd <= PC + 4)
//   uses_rs1, uses_rs2 - instruction really reads rs1 / rs2 (for hazard detection)
//   is_halt   - ECALL / EBREAK
// -----------------------------------------------------------------------------
module control_unit (
    /* verilator lint_off UNUSEDSIGNAL */  // only opcode / funct3 / funct7[5] are decoded
    input  wire [31:0] instr,
    /* verilator lint_on UNUSEDSIGNAL */
    output reg         reg_write,
    output reg  [1:0]  alu_src_a,
    output reg         alu_src_b,
    output reg  [3:0]  alu_ctrl,
    output reg         mem_read,
    output reg         mem_write,
    output reg         wb_sel,
    output reg         branch,
    output reg         jal,
    output reg         jalr,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         is_halt
);

    localparam [6:0] OP_LUI    = 7'b0110111,
                     OP_AUIPC  = 7'b0010111,
                     OP_JAL    = 7'b1101111,
                     OP_JALR   = 7'b1100111,
                     OP_BRANCH = 7'b1100011,
                     OP_LOAD   = 7'b0000011,
                     OP_STORE  = 7'b0100011,
                     OP_IMM    = 7'b0010011,
                     OP_REG    = 7'b0110011,
                     OP_SYSTEM = 7'b1110011;

    localparam [3:0] ALU_ADD = 4'd0, ALU_SUB = 4'd1, ALU_SLL = 4'd2, ALU_SLT = 4'd3,
                     ALU_SLTU = 4'd4, ALU_XOR = 4'd5, ALU_SRL = 4'd6, ALU_SRA = 4'd7,
                     ALU_OR = 4'd8, ALU_AND = 4'd9;

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire       f7_5   = instr[30];

    // ALU operation for OP / OP-IMM from funct3 (+ funct7 bit 5 for SUB / SRA)
    reg [3:0] alu_from_funct;
    always @(*) begin
        case (funct3)
            3'b000:  alu_from_funct = (opcode == OP_REG && f7_5) ? ALU_SUB : ALU_ADD;
            3'b001:  alu_from_funct = ALU_SLL;
            3'b010:  alu_from_funct = ALU_SLT;
            3'b011:  alu_from_funct = ALU_SLTU;
            3'b100:  alu_from_funct = ALU_XOR;
            3'b101:  alu_from_funct = f7_5 ? ALU_SRA : ALU_SRL;
            3'b110:  alu_from_funct = ALU_OR;
            default: alu_from_funct = ALU_AND;
        endcase
    end

    always @(*) begin
        // defaults: NOP
        reg_write = 1'b0;
        alu_src_a = 2'd0;
        alu_src_b = 1'b0;
        alu_ctrl  = ALU_ADD;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        wb_sel    = 1'b0;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        uses_rs1  = 1'b0;
        uses_rs2  = 1'b0;
        is_halt   = 1'b0;
        case (opcode)
            OP_LUI: begin
                reg_write = 1'b1; alu_src_a = 2'd2; alu_src_b = 1'b1;
            end
            OP_AUIPC: begin
                reg_write = 1'b1; alu_src_a = 2'd1; alu_src_b = 1'b1;
            end
            OP_JAL: begin
                reg_write = 1'b1; jal = 1'b1;
            end
            OP_JALR: begin
                reg_write = 1'b1; jalr = 1'b1; alu_src_b = 1'b1; uses_rs1 = 1'b1;
            end
            OP_BRANCH: begin
                branch = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            OP_LOAD: begin
                reg_write = 1'b1; mem_read = 1'b1; wb_sel = 1'b1; alu_src_b = 1'b1; uses_rs1 = 1'b1;
            end
            OP_STORE: begin
                mem_write = 1'b1; alu_src_b = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            OP_IMM: begin
                reg_write = 1'b1; alu_src_b = 1'b1; uses_rs1 = 1'b1; alu_ctrl = alu_from_funct;
            end
            OP_REG: begin
                reg_write = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; alu_ctrl = alu_from_funct;
            end
            OP_SYSTEM: begin
                is_halt = (funct3 == 3'b000);  // ECALL / EBREAK; CSR ops are NOPs
            end
            default: ;  // FENCE and unknown opcodes: NOP
        endcase
    end

endmodule
