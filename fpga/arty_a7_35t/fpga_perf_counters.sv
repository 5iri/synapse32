`default_nettype none
// Board-local profiling page at 0x20001000. Counters may overlap: these are
// event counts, not an additive CPI attribution. Writes to +0 clear all counts.
// Read +0 = "S32P", +4 = version 1; +0x10+8*n = counter n low/high words.
module fpga_perf_counters (
    input wire clk, rst, enable, clear,
    input wire [15:0] events,
    input wire [11:0] addr,
    output reg [31:0] rdata
);
    reg [63:0] counters[0:15];
    wire [3:0] counter_index=addr[6:3]-4'd2;
    integer n;
    always @(posedge clk) begin
        if(rst || clear)
            for(n=0;n<16;n=n+1) counters[n]<=0;
        else if(enable)
            for(n=0;n<16;n=n+1)
                if(events[n]) counters[n]<=counters[n]+1'b1;
    end
    always @(*) begin
        rdata=0;
        if(addr==0) rdata=32'h53333250;
        else if(addr==4) rdata=1;
        else if(addr>=12'h010 && addr<12'h090)
            rdata=addr[2] ? counters[counter_index][63:32] : counters[counter_index][31:0];
    end
endmodule
`default_nettype wire
