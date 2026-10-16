`timescale 1ns/1ps
`include "instr_defines.vh"
module tb_muldiv #(parameter FAST_MULTIPLY=0);
    reg clk=0,rst=1,start=0,consume=0,cancel=0;
    always #5 clk=~clk;
    reg [31:0] lhs,rhs;
    reg [6:0] instr_id;
    wire busy,done;
    wire [31:0] result;
    iterative_muldiv #(.FAST_MULTIPLY(FAST_MULTIPLY)) dut(.*);
    reg [6:0] ops[0:7];
    reg [31:0] a,b,expected;
    reg signed [63:0] product;
    integer i,j,cycles;
    task check(input [6:0] op,input [31:0] a,input [31:0] b);
        begin
            case(op)
                INSTR_MUL: begin product={32'b0,a}*{32'b0,b};expected=product[31:0];end
                INSTR_MULH: begin product=$signed(a)*64'($signed(b));expected=product[63:32];end
                INSTR_MULHSU: begin product=64'($signed(a))*$signed({32'b0,b});expected=product[63:32];end
                INSTR_MULHU: begin product={32'b0,a}*{32'b0,b};expected=product[63:32];end
                INSTR_DIV: begin
                    if(b==0) expected=32'hffffffff;
                    else if(a==32'h80000000&&b==32'hffffffff) expected=a;
                    else expected=$signed(a)/$signed(b);
                end
                INSTR_DIVU: expected=b==0 ? 32'hffffffff : a/b;
                INSTR_REM: begin
                    if(b==0) expected=a;
                    else if(a==32'h80000000&&b==32'hffffffff) expected=0;
                    else expected=$signed(a)%$signed(b);
                end
                default: expected=b==0 ? a : a%b;
            endcase
            @(negedge clk);lhs=a;rhs=b;instr_id=op;start=1;
            @(negedge clk);start=0;cycles=0;
            while(!done&&cycles<40) begin @(negedge clk);cycles=cycles+1;end
            if(!done||result!==expected) $fatal(1,"op=%h a=%h b=%h expected=%h result=%h",op,a,b,expected,result);
            if(FAST_MULTIPLY && (op==INSTR_MUL || op==INSTR_MULH ||
                                 op==INSTR_MULHSU || op==INSTR_MULHU) && cycles!=2)
                $fatal(1,"Fast multiply latency was %0d, expected 2",cycles);
            repeat(3) @(negedge clk);
            if(!done||result!==expected) $fatal(1,"Result lost before consumption");
            consume=1;@(negedge clk);consume=0;
        end
    endtask
    initial begin
        ops[0]=INSTR_MUL;ops[1]=INSTR_MULH;ops[2]=INSTR_MULHSU;ops[3]=INSTR_MULHU;
        ops[4]=INSTR_DIV;ops[5]=INSTR_DIVU;ops[6]=INSTR_REM;ops[7]=INSTR_REMU;
        lhs=0;rhs=0;instr_id=INSTR_MUL;
        repeat(3) @(negedge clk);rst=0;
        for(i=0;i<8;i=i+1) begin
            check(ops[i],32'h80000000,32'hffffffff);
            check(ops[i],32'hffffffff,0);
            check(ops[i],0,32'hffffffff);
            check(ops[i],32'hffffffff,32'hffffffff);
            for(j=0;j<200;j=j+1) check(ops[i],$random,$random);
        end
        @(negedge clk);instr_id=INSTR_DIV;lhs=123;rhs=3;start=1;
        @(negedge clk);start=0;repeat(5) @(negedge clk);cancel=1;
        @(negedge clk);cancel=0;
        if(busy||done) $fatal(1,"Cancelled operation survived");
        check(INSTR_DIV,123,3);
        $display("PASS: 1633 RV32M cases, held results and cancellation");$finish;
    end
endmodule
