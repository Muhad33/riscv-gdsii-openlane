`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// hazard_unit: stall and flush control.
//
// Load-use hazard: the instruction in EX is a load whose rd is read by the
//   instruction in ID. The loaded value only exists after MEM, so the ID
//   instruction waits one cycle: PC and IF/ID hold, a bubble enters ID/EX.
// Control hazard: a taken branch or a jump is resolved in EX (static
//   predict-not-taken). The two younger instructions (in IF and ID) are wrong
//   and are flushed (bubbles into IF/ID and ID/EX); PC loads the target.
// Halt: once ECALL/EBREAK reaches EX, fetching stops and everything younger is
//   flushed, so nothing after the halt instruction ever executes.
//
// Ports:
//   if_id_valid, if_id_rs1, if_id_rs2, uses_rs1, uses_rs2 - instruction in ID
//   id_ex_mem_read, id_ex_rd                              - instruction in EX
//   redirect   - taken branch / jump in EX
//   stop_fetch - halt instruction in EX or already halting
//   stall      - load-use stall this cycle
//   pc_sel     - 2'b00 PC+4, 2'b01 hold, 2'b10 redirect target
//   if_id_flush, if_id_hold, id_ex_flush - pipeline register control
// -----------------------------------------------------------------------------
module hazard_unit (
    input  wire       if_id_valid,
    input  wire [4:0] if_id_rs1,
    input  wire [4:0] if_id_rs2,
    input  wire       uses_rs1,
    input  wire       uses_rs2,
    input  wire       id_ex_mem_read,
    input  wire [4:0] id_ex_rd,
    input  wire       redirect,
    input  wire       stop_fetch,
    output wire       stall,
    output reg  [1:0] pc_sel,
    output wire       if_id_flush,
    output wire       if_id_hold,
    output wire       id_ex_flush
);

    wire load_use = if_id_valid && id_ex_mem_read && (id_ex_rd != 5'd0) &&
                    ((uses_rs1 && id_ex_rd == if_id_rs1) || (uses_rs2 && id_ex_rd == if_id_rs2));

    // a taken branch / halt in EX is older than the ID instruction, so it wins over the stall
    assign stall       = load_use && !redirect && !stop_fetch;
    assign if_id_flush = redirect || stop_fetch;
    assign if_id_hold  = stall;
    assign id_ex_flush = redirect || stop_fetch || stall;

    always @(*) begin
        if (stop_fetch)    pc_sel = 2'b01;
        else if (redirect) pc_sel = 2'b10;
        else if (stall)    pc_sel = 2'b01;
        else               pc_sel = 2'b00;
    end

endmodule
