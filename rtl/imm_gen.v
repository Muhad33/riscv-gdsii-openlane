`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// imm_gen: immediate generator. Extracts and sign-extends the immediate of an
// RV32I instruction according to its format (selected by the opcode).
//
//   I-type: inst[31:20]                                    (loads, OP-IMM, JALR)
//   S-type: inst[31:25] inst[11:7]                         (stores)
//   B-type: inst[31] inst[7] inst[30:25] inst[11:8] 0      (branches)
//   U-type: inst[31:12] << 12                              (LUI, AUIPC)
//   J-type: inst[31] inst[19:12] inst[20] inst[30:21] 0    (JAL)
//
// Ports:
//   instr - 32-bit instruction
//   imm   - sign-extended 32-bit immediate (0 for formats without one)
// -----------------------------------------------------------------------------
module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);

    wire [6:0] opcode = instr[6:0];

    always @(*) begin
        case (opcode)
            7'b0000011, 7'b0010011, 7'b1100111:                       // I-type
                imm = {{20{instr[31]}}, instr[31:20]};
            7'b0100011:                                               // S-type
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            7'b1100011:                                               // B-type
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            7'b0110111, 7'b0010111:                                   // U-type
                imm = {instr[31:12], 12'd0};
            7'b1101111:                                               // J-type
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'd0;
        endcase
    end

endmodule
