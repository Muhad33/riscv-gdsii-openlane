`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// regfile: 32 x 32-bit register file, 2 asynchronous read ports, 1 write port.
//
// - x0 always reads as zero and writes to it are ignored.
// - Write-before-read: if the WB stage writes a register in the same cycle the
//   ID stage reads it, the read port returns the new value (internal bypass),
//   so no extra forwarding path from WB to ID is needed.
// - Writes happen on the rising clock edge. Synchronous reset clears all registers.
//
// Ports:
//   clk, rst          - clock, synchronous active-high reset
//   raddr1, raddr2    - read addresses (rs1, rs2)
//   rdata1, rdata2    - read data
//   we, waddr, wdata  - write enable, address (rd), data
// -----------------------------------------------------------------------------
module regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata
);

    reg [31:0] regs [1:31];
    integer i;

    wire wr = we && (waddr != 5'd0);

    always @(posedge clk) begin
        if (rst) begin
            for (i = 1; i < 32; i = i + 1)
                regs[i] <= 32'd0;
        end else if (wr) begin
            regs[waddr] <= wdata;
        end
    end

    assign rdata1 = (raddr1 == 5'd0)            ? 32'd0 :
                    (wr && waddr == raddr1)     ? wdata : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0)            ? 32'd0 :
                    (wr && waddr == raddr2)     ? wdata : regs[raddr2];

endmodule
