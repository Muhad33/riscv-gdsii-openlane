`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// cpu_top: 5-stage pipelined RV32I core (IF, ID, EX, MEM, WB) with separate
// instruction ROM and data RAM.
//
// Pipeline registers (inline below): IF/ID, ID/EX, EX/MEM, MEM/WB. Each carries a
// 'valid' bit; a bubble is valid = 0 with all write/branch controls cleared.
//
// Hazards:
//   - Data: full forwarding from EX/MEM and MEM/WB into EX (forwarding_unit),
//     register file write-before-read covers WB -> ID, and a one-cycle stall for
//     load-use pairs (hazard_unit).
//   - Control: branches and jumps resolve in EX (static predict-not-taken);
//     when taken, the two younger instructions are flushed (2-cycle penalty).
//   - Structural: none (separate instruction and data memories).
//
// Halt: ECALL or EBREAK. When it reaches EX, fetching stops and younger
// instructions are flushed; when it reaches WB, 'halted' goes high one cycle
// later. Every instruction before it has then completed.
//
// Memory map: instruction ROM at 0x0000_0000 (4 KiB), data RAM at 0x0001_0000
// (4 KiB). The reset PC is 0x0000_0000.
//
// Parameters:
//   IMEM_WORDS, DMEM_WORDS - memory sizes in 32-bit words
//   DMEM_BASE              - data RAM base address
//   IMEM_FILE, DMEM_FILE   - optional hex files to preload
// Ports:
//   clk, rst      - clock, synchronous active-high reset
//   halted        - goes high after the halt instruction retires (stays high)
//   cycle_count   - clock cycles since reset (stops when halted)
//   instret_count - instructions retired (reached WB), including the halt
// -----------------------------------------------------------------------------
module cpu_top #(
    parameter IMEM_WORDS = 1024,
    parameter DMEM_WORDS = 1024,
    parameter DMEM_BASE  = 32'h0001_0000,
    parameter IMEM_FILE  = "",
    parameter DMEM_FILE  = ""
) (
    input  wire        clk,
    input  wire        rst,
    output reg         halted,
    output reg  [31:0] cycle_count,
    output reg  [31:0] instret_count
);

    // =========================================================================
    // IF stage
    // =========================================================================
    reg  [31:0] pc;
    wire [31:0] if_instr;
    wire [31:0] pc_plus4 = pc + 32'd4;

    instr_mem #(.WORDS(IMEM_WORDS), .MEM_FILE(IMEM_FILE)) u_imem (
        .addr(pc), .instr(if_instr)
    );

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
    reg [31:0] ex_mem_pc, ex_mem_result, ex_mem_store_data;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;

    reg        mem_wb_valid, mem_wb_reg_write, mem_wb_wb_sel, mem_wb_is_halt;
    reg [31:0] mem_wb_pc, mem_wb_result, mem_wb_load_data;
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
    wire       stall, if_id_flush, if_id_hold, id_ex_flush;
    wire [1:0] pc_sel;

    hazard_unit u_hazard (
        .if_id_valid(if_id_valid), .if_id_rs1(id_rs1), .if_id_rs2(id_rs2),
        .uses_rs1(c_uses_rs1), .uses_rs2(c_uses_rs2),
        .id_ex_mem_read(id_ex_valid & id_ex_mem_read), .id_ex_rd(id_ex_rd),
        .redirect(ex_redirect), .stop_fetch(stop_fetch),
        .stall(stall), .pc_sel(pc_sel), .if_id_flush(if_id_flush), .if_id_hold(if_id_hold),
        .id_ex_flush(id_ex_flush)
    );

    // =========================================================================
    // MEM stage
    // =========================================================================
    wire [31:0] mem_load_data;

    data_mem #(.WORDS(DMEM_WORDS), .BASE(DMEM_BASE), .MEM_FILE(DMEM_FILE)) u_dmem (
        .clk(clk),
        .we(ex_mem_valid & ex_mem_mem_write),
        .re(ex_mem_valid & ex_mem_mem_read),
        .funct3(ex_mem_funct3),
        .addr(ex_mem_result),
        .wdata(ex_mem_store_data),
        .rdata(mem_load_data)
    );

    // =========================================================================
    // WB stage
    // =========================================================================
    assign wb_we   = mem_wb_valid & mem_wb_reg_write;
    assign wb_rd   = mem_wb_rd;
    assign wb_data = mem_wb_wb_sel ? mem_wb_load_data : mem_wb_result;

    // =========================================================================
    // Sequential logic: PC and pipeline registers
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
            ex_mem_pc         <= 32'd0;
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
            ex_mem_pc         <= id_ex_pc;
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
            mem_wb_pc        <= 32'd0;
            mem_wb_result    <= 32'd0;
            mem_wb_load_data <= 32'd0;
            mem_wb_rd        <= 5'd0;
        end else begin
            mem_wb_valid     <= 1'b1;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_wb_sel    <= ex_mem_wb_sel;
            mem_wb_is_halt   <= ex_mem_is_halt;
            mem_wb_pc        <= ex_mem_pc;
            mem_wb_result    <= ex_mem_result;
            mem_wb_load_data <= mem_load_data;
            mem_wb_rd        <= ex_mem_rd;
        end
    end

    // Halt flag and performance counters
    always @(posedge clk) begin
        if (rst) begin
            halted        <= 1'b0;
            cycle_count   <= 32'd0;
            instret_count <= 32'd0;
        end else if (!halted) begin
            cycle_count <= cycle_count + 32'd1;
            if (mem_wb_valid)
                instret_count <= instret_count + 32'd1;
            if (mem_wb_valid && mem_wb_is_halt)
                halted <= 1'b1;
        end
    end

endmodule
