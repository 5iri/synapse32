`timescale 1ns/1ps
module tb_perf_counters;
    reg clk=0,rst=1,enable=0,clear=0;
    always #5 clk=~clk;
    reg [15:0] events=0;
    reg [11:0] addr=0;
    wire [31:0] rdata;
    fpga_perf_counters dut(.*);
    integer i;
    task read_check(input [11:0] offset,input [31:0] expected);
        addr=offset;#1;
        if(rdata!==expected) $fatal(1,"offset=%h got=%h expected=%h",offset,rdata,expected);
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        read_check(0,32'h53333250);read_check(4,1);
        enable=1;events=16'ha55a;
        repeat(7) @(negedge clk);
        enable=0;
        for(i=0;i<16;i=i+1) begin
            read_check(12'(16+8*i),events[i] ? 7 : 0);
            read_check(12'(20+8*i),0);
        end
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        for(i=0;i<16;i=i+1) read_check(12'(16+8*i),0);
        read_check(12'h090,0);read_check(12'h00c,0);
        $display("PASS: profiling signature, 16 independent counters, disable and clear");
        $finish;
    end
endmodule
