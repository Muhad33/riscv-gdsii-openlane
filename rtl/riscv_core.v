`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// riscv_core: 5-stage pipelined RV32I core (IF, ID, EX, MEM, WB), ASIC version.
//
// Same micro-architecture as ref/cpu_top.v (cycle-exact), but the instruction
// and data memories are OUTSIDE the core and reached through ports, so they
// are not synthesized as flip-flop arrays. The 32 x 32 register file stays
// inside. Fully synthesizable: no $readmemh, initial blocks, delays or
// $display; synchronous active-high reset only.
//
// Pipeline (unchanged from the reference):
//   - full forwarding EX/MEM, MEM/WB -> EX; register file write-before-read;
//     1-cycle load-use stall
//   - branches / jumps resolve in EX (predict-not-taken, 2-cycle penalty)
//   - ECALL / EBREAK = halt: when it reaches EX fetching stops and younger
//     instructions are flushed; when it reaches WB, 'halted' goes high one
//     cycle later and stays high until reset.
//
// Memory interface (both memories are word-organized, little-endian):
//   Instruction memory (read-only, combinational read):
//     imem_addr  - byte address = PC (bits [1:0] are always 0)
//     imem_rdata - instruction word at imem_addr, valid in the same cycle
//   Data memory (combinational read, write on the rising clock edge):
//     dmem_addr  - byte address of the access (bits [1:0] = byte offset)
//     dmem_re    - load in progress
//     dmem_we    - store: write the enabled bytes of dmem_wdata at the next edge
//     dmem_be    - byte enables for the store (bit i -> bits 8i+7..8i)
//     dmem_wdata - store data, already shifted into the right byte lanes
//     dmem_rdata - full 32-bit word at word address dmem_addr[31:2];
//                  the core selects / sign-extends the byte or halfword
//   Address decoding (which addresses exist, out-of-range behaviour) is the
//   memory system's job.
//
// Retire / trace port (zero logic cost: these are the WB-stage signals that
// already drive the register-file write port). Used by the testbench to count
// retired instructions and to check every register write against the golden
// model, also on the gate-level netlist where internal names are gone.
//   retire_valid - an instruction is in WB this cycle (it retires at the edge)
//   retire_we    - it writes rd (rd may be x0; x0 writes are discarded)
//   retire_rd    - destination register
//   retire_wdata - value written
// -----------------------------------------------------------------------------
module riscv_core (
    input  wire        clk,
    input  wire        rst,

    // instruction memory
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // data memory
    output wire [31:0] dmem_addr,
    output wire        dmem_re,
    output wire        dmem_we,
    output reg  [3:0]  dmem_be,
    output reg  [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,

    // status
    output reg         halted,

    // retire / trace port
    output wire        retire_valid,
    output wire        retire_we,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_wdata
);

    // =========================================================================
    // IF stage
    // =========================================================================
    reg  [31:0] pc;
    wire [31:0] if_instr = imem_rdata;
    wire [31:0] pc_plus4 = pc + 32'd4;

    assign imem_addr = pc;

    // IF/ID
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // =========================================================================
    // ID stage
    // =========================================================================
    wire [4:0] id_rs1 = if_id_instr[19:15];
    wire [4:0] id_rs2 = if_id_instr[24:20];
    wire [4:0] id_rd  = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];

    wire        c_reg_write, c_alu_src_b, c_mem_read, c_mem_write, c_wb_sel;
    wire        c_branch, c_jal, c_jalr, c_uses_rs1, c_uses_rs2, c_is_halt;
    wire [1:0]  c_alu_src_a;
    wire [3:0]  c_alu_ctrl;
    wire [31:0] id_imm, id_rdata1, id_rdata2;

    control_unit u_ctrl (
        .instr(if_id_instr), .reg_write(c_reg_write), .alu_src_a(c_alu_src_a), .alu_src_b(c_alu_src_b),
        .alu_ctrl(c_alu_ctrl), .mem_read(c_mem_read), .mem_write(c_mem_write), .wb_sel(c_wb_sel),
        .branch(c_branch), .jal(c_jal), .jalr(c_jalr), .uses_rs1(c_uses_rs1), .uses_rs2(c_uses_rs2),
        .is_halt(c_is_halt)
    );

    imm_gen u_imm (.instr(if_id_instr), .imm(id_imm));

    // write-back signals (defined in WB section) feed the register file
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    regfile u_rf (
        .clk(clk), .rst(rst),
        .raddr1(id_rs1), .raddr2(id_rs2), .rdata1(id_rdata1), .rdata2(id_rdata2),
        .we(wb_we), .waddr(wb_rd), .wdata(wb_data)
    );

    // ID/EX
    reg        id_ex_valid;
    reg [31:0] id_ex_pc, id_ex_rdata1, id_ex_rdata2, id_ex_imm;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_reg_write, id_ex_alu_src_b, id_ex_mem_read, id_ex_mem_write, id_ex_wb_sel;
    reg        id_ex_branch, id_ex_jal, id_ex_jalr, id_ex_is_halt;
    reg [1:0]  id_ex_alu_src_a;
    reg [3:0]  id_ex_alu_ctrl;

    // =========================================================================
    // EX stage
    // =========================================================================
    // EX/MEM and MEM/WB registers (used by forwarding)
    reg        ex_mem_valid, ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write, ex_mem_wb_sel, ex_mem_is_halt;
    reg [31:0] ex_mem_result, ex_mem_store_data;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;

    reg        mem_wb_valid, mem_wb_reg_write, mem_wb_wb_sel, mem_wb_is_halt;
    reg [31:0] mem_wb_result, mem_wb_load_data;
    reg [4:0]  mem_wb_rd;

    wire [1:0] forward_a, forward_b;
    forwarding_unit u_fwd (
        .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
        .ex_mem_rd(ex_mem_rd), .ex_mem_reg_write(ex_mem_valid & ex_mem_reg_write),
        .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_valid & mem_wb_reg_write),
        .forward_a(forward_a), .forward_b(forward_b)
    );

    wire [31:0] ex_rs1_val = (forward_a == 2'b10) ? ex_mem_result :
                             (forward_a == 2'b01) ? wb_data : id_ex_rdata1;
    wire [31:0] ex_rs2_val = (forward_b == 2'b10) ? ex_mem_result :
                             (forward_b == 2'b01) ? wb_data : id_ex_rdata2;

    wire [31:0] alu_a = (id_ex_alu_src_a == 2'd1) ? id_ex_pc :
                        (id_ex_alu_src_a == 2'd2) ? 32'd0 : ex_rs1_val;
    wire [31:0] alu_b = id_ex_alu_src_b ? id_ex_imm : ex_rs2_val;
    wire [31:0] alu_out;

    alu u_alu (.a(alu_a), .b(alu_b), .alu_ctrl(id_ex_alu_ctrl), .result(alu_out));

    // Branch comparator (funct3: 000 BEQ, 001 BNE, 100 BLT, 101 BGE, 110 BLTU, 111 BGEU)
    reg br_cond;
    always @(*) begin
        case (id_ex_funct3)
            3'b000:  br_cond = (ex_rs1_val == ex_rs2_val);
            3'b001:  br_cond = (ex_rs1_val != ex_rs2_val);
            3'b100:  br_cond = ($signed(ex_rs1_val) <  $signed(ex_rs2_val));
            3'b101:  br_cond = ($signed(ex_rs1_val) >= $signed(ex_rs2_val));
            3'b110:  br_cond = (ex_rs1_val <  ex_rs2_val);
            3'b111:  br_cond = (ex_rs1_val >= ex_rs2_val);
            default: br_cond = 1'b0;
        endcase
    end

    wire        ex_redirect = id_ex_valid && ((id_ex_branch && br_cond) || id_ex_jal || id_ex_jalr);
    wire [31:0] ex_target   = id_ex_jalr ? (alu_out & 32'hFFFF_FFFE) : (id_ex_pc + id_ex_imm);
    wire [31:0] ex_link     = id_ex_pc + 32'd4;
    wire [31:0] ex_result   = (id_ex_jal || id_ex_jalr) ? ex_link : alu_out;  // rd value of the instruction

    // Halt control: ECALL/EBREAK in EX stops fetching from now on
    reg  halting;
    wire ex_halt    = id_ex_valid && id_ex_is_halt;
    wire stop_fetch = ex_halt || halting;

    // =========================================================================
    // Hazard unit
    // =========================================================================
    wire       if_id_flush, if_id_hold, id_ex_flush;
    wire [1:0] pc_sel;

    /* verilator lint_off PINCONNECTEMPTY */  // 'stall' is only used by the reference design's trace
    hazard_unit u_hazard (
        .if_id_valid(if_id_valid), .if_id_rs1(id_rs1), .if_id_rs2(id_rs2),
        .uses_rs1(c_uses_rs1), .uses_rs2(c_uses_rs2),
        .id_ex_mem_read(id_ex_valid & id_ex_mem_read), .id_ex_rd(id_ex_rd),
        .redirect(ex_redirect), .stop_fetch(stop_fetch),
        .stall(), .pc_sel(pc_sel), .if_id_flush(if_id_flush), .if_id_hold(if_id_hold),
        .id_ex_flush(id_ex_flush)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // =========================================================================
    // MEM stage: data memory interface
    // =========================================================================
    wire [1:0] mem_off = ex_mem_result[1:0];

    assign dmem_addr = ex_mem_result;
    assign dmem_re   = ex_mem_valid & ex_mem_mem_read;
    assign dmem_we   = ex_mem_valid & ex_mem_mem_write;

    // store: byte enables and lane placement (funct3[1:0]: 00 SB, 01 SH, 1x SW)
    always @(*) begin
        case (ex_mem_funct3[1:0])
            2'b00: begin
                dmem_wdata = {4{ex_mem_store_data[7:0]}};
                case (mem_off)
                    2'd0:    dmem_be = 4'b0001;
                    2'd1:    dmem_be = 4'b0010;
                    2'd2:    dmem_be = 4'b0100;
                    default: dmem_be = 4'b1000;
                endcase
            end
            2'b01: begin
                dmem_wdata = {2{ex_mem_store_data[15:0]}};
                dmem_be    = mem_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                dmem_wdata = ex_mem_store_data;
                dmem_be    = 4'b1111;
            end
        endcase
    end

    // load: select and extend (funct3: 000 LB, 001 LH, 010 LW, 100 LBU, 101 LHU)
    reg  [7:0]  ld_byte;
    reg  [31:0] mem_load_data;
    wire [15:0] ld_half = mem_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    always @(*) begin
        case (mem_off)
            2'd0:    ld_byte = dmem_rdata[7:0];
            2'd1:    ld_byte = dmem_rdata[15:8];
            2'd2:    ld_byte = dmem_rdata[23:16];
            default: ld_byte = dmem_rdata[31:24];
        endcase
        case (ex_mem_funct3)
            3'b000:  mem_load_data = {{24{ld_byte[7]}}, ld_byte};   // LB
            3'b001:  mem_load_data = {{16{ld_half[15]}}, ld_half};  // LH
            3'b100:  mem_load_data = {24'd0, ld_byte};              // LBU
            3'b101:  mem_load_data = {16'd0, ld_half};              // LHU
            default: mem_load_data = dmem_rdata;                    // LW
        endcase
    end

    // =========================================================================
    // WB stage
    // =========================================================================
    assign wb_we   = mem_wb_valid & mem_wb_reg_write;
    assign wb_rd   = mem_wb_rd;
    assign wb_data = mem_wb_wb_sel ? mem_wb_load_data : mem_wb_result;

    assign retire_valid = mem_wb_valid;
    assign retire_we    = wb_we;
    assign retire_rd    = wb_rd;
    assign retire_wdata = wb_data;

    // =========================================================================
    // Sequential logic: PC and pipeline registers (synchronous reset)
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            pc      <= 32'd0;
            halting <= 1'b0;
        end else begin
            case (pc_sel)
                2'b00:   pc <= pc_plus4;
                2'b10:   pc <= ex_target;
                default: pc <= pc;
            endcase
            if (ex_halt)
                halting <= 1'b1;
        end
    end

    // IF/ID
    always @(posedge clk) begin
        if (rst || if_id_flush) begin
            if_id_valid <= 1'b0;
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'h0000_0013;  // NOP
        end else if (!if_id_hold) begin
            if_id_valid <= 1'b1;
            if_id_pc    <= pc;
            if_id_instr <= if_instr;
        end
    end

    // ID/EX
    always @(posedge clk) begin
        if (rst || id_ex_flush || !if_id_valid) begin
            id_ex_valid     <= 1'b0;
            id_ex_reg_write <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_branch    <= 1'b0;
            id_ex_jal       <= 1'b0;
            id_ex_jalr      <= 1'b0;
            id_ex_is_halt   <= 1'b0;
            id_ex_wb_sel    <= 1'b0;
            id_ex_alu_src_a <= 2'd0;
            id_ex_alu_src_b <= 1'b0;
            id_ex_alu_ctrl  <= 4'd0;
            id_ex_pc        <= 32'd0;
            id_ex_rdata1    <= 32'd0;
            id_ex_rdata2    <= 32'd0;
            id_ex_imm       <= 32'd0;
            id_ex_rs1       <= 5'd0;
            id_ex_rs2       <= 5'd0;
            id_ex_rd        <= 5'd0;
            id_ex_funct3    <= 3'd0;
        end else begin
            id_ex_valid     <= 1'b1;
            id_ex_reg_write <= c_reg_write;
            id_ex_mem_read  <= c_mem_read;
            id_ex_mem_write <= c_mem_write;
            id_ex_branch    <= c_branch;
            id_ex_jal       <= c_jal;
            id_ex_jalr      <= c_jalr;
            id_ex_is_halt   <= c_is_halt;
            id_ex_wb_sel    <= c_wb_sel;
            id_ex_alu_src_a <= c_alu_src_a;
            id_ex_alu_src_b <= c_alu_src_b;
            id_ex_alu_ctrl  <= c_alu_ctrl;
            id_ex_pc        <= if_id_pc;
            id_ex_rdata1    <= id_rdata1;
            id_ex_rdata2    <= id_rdata2;
            id_ex_imm       <= id_imm;
            id_ex_rs1       <= c_uses_rs1 ? id_rs1 : 5'd0;  // unused fields never forward / stall
            id_ex_rs2       <= c_uses_rs2 ? id_rs2 : 5'd0;
            id_ex_rd        <= c_reg_write ? id_rd : 5'd0;
            id_ex_funct3    <= id_funct3;
        end
    end

    // EX/MEM
    always @(posedge clk) begin
        if (rst || !id_ex_valid) begin
            ex_mem_valid      <= 1'b0;
            ex_mem_reg_write  <= 1'b0;
            ex_mem_mem_read   <= 1'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_wb_sel     <= 1'b0;
            ex_mem_is_halt    <= 1'b0;
            ex_mem_result     <= 32'd0;
            ex_mem_store_data <= 32'd0;
            ex_mem_rd         <= 5'd0;
            ex_mem_funct3     <= 3'd0;
        end else begin
            ex_mem_valid      <= 1'b1;
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_mem_read   <= id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_wb_sel     <= id_ex_wb_sel;
            ex_mem_is_halt    <= id_ex_is_halt;
            ex_mem_result     <= ex_result;
            ex_mem_store_data <= ex_rs2_val;
            ex_mem_rd         <= id_ex_rd;
            ex_mem_funct3     <= id_ex_funct3;
        end
    end

    // MEM/WB
    always @(posedge clk) begin
        if (rst || !ex_mem_valid) begin
            mem_wb_valid     <= 1'b0;
            mem_wb_reg_write <= 1'b0;
            mem_wb_wb_sel    <= 1'b0;
            mem_wb_is_halt   <= 1'b0;
            mem_wb_result    <= 32'd0;
            mem_wb_load_data <= 32'd0;
            mem_wb_rd        <= 5'd0;
        end else begin
            mem_wb_valid     <= 1'b1;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_wb_sel    <= ex_mem_wb_sel;
            mem_wb_is_halt   <= ex_mem_is_halt;
            mem_wb_result    <= ex_mem_result;
            mem_wb_load_data <= mem_load_data;
            mem_wb_rd        <= ex_mem_rd;
        end
    end

    // Halt flag: set one cycle after ECALL/EBREAK retires, held until reset
    always @(posedge clk) begin
        if (rst)
            halted <= 1'b0;
        else if (mem_wb_valid && mem_wb_is_halt)
            halted <= 1'b1;
    end

endmodule
