`timescale 1ns/1ps
`default_nettype none
module tb_l1_bank #(parameter LINES=4, REGISTER_WRITES=0);
    reg clk=0,rst=1,lookup=0,fill=0,snoop=0,snoop_error=0;
    always #5 clk=~clk;
    reg [31:0] lookup_addr=0,fill_addr=0,snoop_addr=0,snoop_data=0;
    reg [127:0] fill_data=0;
    reg [3:0] snoop_be=0;
    wire hit;
    wire [31:0] word_data;
    physical_l1_cache #(.LINES(LINES),.REGISTER_WRITES(REGISTER_WRITES)) dut(.*);
    task automatic check(input [31:0] address,input bit expected_hit,input [31:0] expected);
        begin
            @(negedge clk);lookup=1;lookup_addr=address;
            @(negedge clk);lookup=0;
            if(hit!==expected_hit || (expected_hit&&word_data!==expected))
                $fatal(1,"lookup %h hit=%b data=%h expected hit=%b data=%h",address,hit,word_data,expected_hit,expected);
        end
    endtask
    task automatic load(input [31:0] address,input [127:0] line_value);
        begin
            @(negedge clk);fill=1;fill_addr=address;fill_data=line_value;
            @(negedge clk);fill=0;
        end
    endtask
    task automatic store(input [31:0] address,input [31:0] data,input [3:0] strobes,input bit error=0);
        begin
            @(negedge clk);snoop=1;snoop_addr=address;snoop_data=data;snoop_be=strobes;snoop_error=error;
            @(negedge clk);snoop=0;snoop_error=0;
        end
    endtask
    localparam PRESENT=(LINES>0);
    localparam [31:0] CONFLICT=32'h80000000+((LINES>0 ? LINES : 1)*16);
    initial begin
        repeat(3) @(negedge clk);rst=0;
        check(32'h80000000,0,0);
        load(32'h80000000,128'hffeeddccbbaa99887766554433221100);
        check(32'h80000000,PRESENT,32'h33221100);
        check(32'h8000000c,PRESENT,32'hffeeddcc);
        store(32'h80000001,32'ha5,1);
        check(32'h80000000,PRESENT,32'h3322a500);
        // RAM cross-port read/write collision: output forwards written bytes.
        @(negedge clk);lookup=1;lookup_addr=32'h80000004;
        snoop=1;snoop_addr=32'h80000004;snoop_data=32'hdeadc0de;snoop_be=5;
        @(negedge clk);lookup=0;snoop=0;
        if(hit!==PRESENT || (PRESENT&&word_data!==32'h77ad55de))
            $fatal(1,"simultaneous lookup/store did not forward sparse byte enables");
        check(32'h80000004,PRESENT,32'h77ad55de);
        // Failed writes invalidate, including a lookup on that same edge.
        @(negedge clk);lookup=1;lookup_addr=32'h80000000;
        snoop=1;snoop_addr=32'h80000008;snoop_data=32'hbadbad;snoop_be=15;snoop_error=1;
        @(negedge clk);lookup=0;snoop=0;snoop_error=0;
        if(hit) $fatal(1,"error collision exposed a cached line");
        check(32'h80000000,0,0);
        load(32'h80000000,128'hffeeddccbbaa99887766554433221100);
        load(CONFLICT,128'h44444444333333332222222211111111);
        check(32'h80000000,0,0);
        check(CONFLICT,PRESENT,32'h11111111);
        // BRAM cross-port fill/read collisions never rely on READ_FIRST mode.
        @(negedge clk);lookup=1;lookup_addr=CONFLICT;
        fill=1;fill_addr=32'h80000000;fill_data=128'h0123456789abcdef0123456789abcdef;
        @(negedge clk);lookup=0;fill=0;
        if(hit) $fatal(1,"conflicting fill exposed undefined cross-port read data");
        @(negedge clk);lookup=1;lookup_addr=32'h80000004;
        fill=1;fill_addr=32'h80000000;fill_data=128'h44444444333333332222222211111111;
        @(negedge clk);lookup=0;fill=0;
        if(hit!==PRESENT || (PRESENT&&word_data!==32'h22222222)) $fatal(1,"same-line fill was not forwarded");
        @(negedge clk);rst=1;
        @(negedge clk);rst=0;
        check(CONFLICT,0,0);
        $display("PASS: L1 bank lines=%0d registered_writes=%0d fill/tags/byte snoops/collision forwarding/error/reset",LINES,REGISTER_WRITES);
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
