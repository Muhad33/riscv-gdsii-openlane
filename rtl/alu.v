`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// alu: RV32I arithmetic / logic unit (purely combinational).
//
// Ports:
//   a, b     - 32-bit operands
//   alu_ctrl - operation select (see localparams below, shared with control_unit)
//   result   - 32-bit result
// Shifts use b[4:0] as the shift amount; SLT / SLTU return 0 or 1.
// -----------------------------------------------------------------------------
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_ctrl,
    output reg  [31:0] result
);

    localparam [3:0] ALU_ADD  = 4'd0,
                     ALU_SUB  = 4'd1,
                     ALU_SLL  = 4'd2,
                     ALU_SLT  = 4'd3,
                     ALU_SLTU = 4'd4,
                     ALU_XOR  = 4'd5,
                     ALU_SRL  = 4'd6,
                     ALU_SRA  = 4'd7,
                     ALU_OR   = 4'd8,
                     ALU_AND  = 4'd9;

    always @(*) begin
        case (alu_ctrl)
            ALU_ADD:  result = a + b;
            ALU_SUB:  result = a - b;
            ALU_SLL:  result = a << b[4:0];
            ALU_SLT:  result = {31'd0, $signed(a) < $signed(b)};
            ALU_SLTU: result = {31'd0, a < b};
            ALU_XOR:  result = a ^ b;
            ALU_SRL:  result = a >> b[4:0];
            ALU_SRA:  result = $signed(a) >>> b[4:0];
            ALU_OR:   result = a | b;
            ALU_AND:  result = a & b;
            default:  result = 32'd0;
        endcase
    end

endmodule
