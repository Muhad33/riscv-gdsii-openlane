`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// data_mem: data RAM with byte / halfword / word access.
//
// Memory map: BASE .. BASE + 4*WORDS - 1 (default 0x0001_0000 .. 0x0001_0FFF).
// Accesses outside that range: writes are ignored, reads return 0.
// Writes are synchronous (rising edge) with byte enables; reads are asynchronous
// (combinational) so a load gets its data within the MEM stage.
// Halfword accesses must be 2-byte aligned and word accesses 4-byte aligned
// (RV32I allows any byte offset inside the word for byte accesses).
//
// funct3 (from the load/store instruction):
//   000 LB/SB  001 LH/SH  010 LW/SW  100 LBU  101 LHU
//   LB/LH sign-extend, LBU/LHU zero-extend.
//
// Parameters:
//   WORDS    - number of 32-bit words (default 1024 = 4 KiB)
//   BASE     - base byte address (must be aligned to the memory size)
//   MEM_FILE - optional hex file to preload (.data section)
// Ports:
//   clk          - clock
//   we, re       - write / read enable
//   funct3       - access size and signedness
//   addr         - byte address
//   wdata        - store data (value of rs2)
//   rdata        - load data, already extended to 32 bits
// -----------------------------------------------------------------------------
module data_mem #(
    parameter WORDS    = 1024,
    parameter BASE     = 32'h0001_0000,
    parameter MEM_FILE = ""
) (
    input  wire        clk,
    input  wire        we,
    input  wire        re,
    input  wire [2:0]  funct3,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata
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

    localparam AW = clog2(WORDS);  // word-address bits

    reg [31:0] mem [0:WORDS-1];
    integer i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'd0;
        if (MEM_FILE != "")
            $readmemh(MEM_FILE, mem);
    end

    wire          in_range = (addr[31:AW+2] == BASE[31:AW+2]);
    wire [AW-1:0] widx     = addr[AW+1:2];
    wire [1:0]    off      = addr[1:0];

    // ---------------------------------------------------------------- write
    reg [3:0]  be;
    reg [31:0] wword;
    always @(*) begin
        case (funct3[1:0])
            2'b00: begin be = 4'b0001 << off;               wword = {4{wdata[7:0]}};  end  // SB
            2'b01: begin be = off[1] ? 4'b1100 : 4'b0011;   wword = {2{wdata[15:0]}}; end  // SH
            default: begin be = 4'b1111;                    wword = wdata;            end  // SW
        endcase
    end

    always @(posedge clk) begin
        if (we && in_range) begin
            if (be[0]) mem[widx][7:0]   <= wword[7:0];
            if (be[1]) mem[widx][15:8]  <= wword[15:8];
            if (be[2]) mem[widx][23:16] <= wword[23:16];
            if (be[3]) mem[widx][31:24] <= wword[31:24];
        end
    end

    // ---------------------------------------------------------------- read
    wire [31:0] word  = in_range ? mem[widx] : 32'd0;
    wire [7:0]  byte_ = word >> {off, 3'b000};
    wire [15:0] half  = off[1] ? word[31:16] : word[15:0];

    always @(*) begin
        if (!re) begin
            rdata = 32'd0;
        end else begin
            case (funct3)
                3'b000:  rdata = {{24{byte_[7]}}, byte_};  // LB
                3'b001:  rdata = {{16{half[15]}}, half};   // LH
                3'b100:  rdata = {24'd0, byte_};           // LBU
                3'b101:  rdata = {16'd0, half};            // LHU
                default: rdata = word;                     // LW
            endcase
        end
    end

endmodule
