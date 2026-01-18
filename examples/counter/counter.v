// 8-bit up counter with synchronous reset and enable.
// Used only to prove the LibreLane + sky130 installation works end to end.
module counter (
    input  wire       clk,
    input  wire       rst,   // synchronous, active high
    input  wire       en,
    output reg  [7:0] count
);
    always @(posedge clk) begin
        if (rst)
            count <= 8'd0;
        else if (en)
            count <= count + 8'd1;
    end
endmodule
