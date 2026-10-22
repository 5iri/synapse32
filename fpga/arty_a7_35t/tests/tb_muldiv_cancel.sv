`timescale 1ns/1ps
`include "instr_defines.vh"
module tb_muldiv_cancel #(parameter FAST_MULTIPLY=0);
    reg clk=0,rst=1,cancel=0,start=0,consume=0;
    always #5 clk=~clk;
    reg [6:0] instr_id=INSTR_MUL;
    reg [31:0] lhs=0,rhs=0;
    wire busy,done;
    wire [31:0] result;
    iterative_muldiv #(.FAST_MULTIPLY(FAST_MULTIPLY)) dut(.*);
    reg [6:0] operations[0:7];
    integer cancellations=0,restarts=0;
    // Independent behavioral oracle: no use of the iterative DUT state or
    // shift/subtract algorithm. Signed overflow and divide-by-zero follow RV32M.
    function automatic [31:0] arithmetic(input [6:0] op,input [31:0] a,input [31:0] b);
        reg signed [63:0] signed_a,signed_b,signed_product;
        reg [63:0] unsigned_product;
        begin
            signed_a={{32{a[31]}},a};signed_b={{32{b[31]}},b};
            signed_product=0;unsigned_product={32'b0,a}*{32'b0,b};
            case(op)
                INSTR_MUL:arithmetic=unsigned_product[31:0];
                INSTR_MULH:begin signed_product=signed_a*signed_b;arithmetic=signed_product[63:32];end
                INSTR_MULHSU:begin signed_product=signed_a*$signed({32'b0,b});arithmetic=signed_product[63:32];end
                INSTR_MULHU:arithmetic=unsigned_product[63:32];
                INSTR_DIV:begin
                    if(b==0) arithmetic=32'hffffffff;
                    else if(a==32'h80000000&&b==32'hffffffff) arithmetic=a;
                    else arithmetic=$signed(a)/$signed(b);
                end
                INSTR_DIVU:arithmetic=b==0 ? 32'hffffffff : a/b;
                INSTR_REM:begin
                    if(b==0) arithmetic=a;
                    else if(a==32'h80000000&&b==32'hffffffff) arithmetic=0;
                    else arithmetic=$signed(a)%$signed(b);
                end
                default:arithmetic=b==0 ? a : a%b;
            endcase
        end
    endfunction
    task automatic tick;
        begin @(posedge clk);#1;@(negedge clk);end
    endtask
    task automatic canceled_state;
        begin
            if(busy||done||result!==32'b0)
                $fatal(1,"cancel leaked state fast=%0d busy=%b done=%b result=%h",FAST_MULTIPLY,busy,done,result);
        end
    endtask
    task automatic restart_check(input integer next_op,input integer pattern);
        reg [31:0] a,b,expected;
        integer cycles;
        begin
            case(pattern%4)
                0:begin a=32'h80000000;b=32'hffffffff;end
                1:begin a=32'habcdef01;b=0;end
                2:begin a=32'hf1234567;b=32'h12345;end
                default:begin a=32'h12345678;b=32'hfedcba98;end
            endcase
            expected=arithmetic(operations[next_op],a,b);
            instr_id=operations[next_op];lhs=a;rhs=b;start=1;tick();start=0;
            cycles=0;
            while(!done&&cycles<40) begin
                if(!busy||result!==0) $fatal(1,"restart leaked a stale/partial result before done");
                tick();cycles=cycles+1;
            end
            if(!done||busy||result!==expected)
                $fatal(1,"restart arithmetic fast=%0d op=%h a=%h b=%h got=%h want=%h cycles=%0d",FAST_MULTIPLY,instr_id,a,b,result,expected,cycles);
            repeat(3) begin
                tick();
                if(!done||busy||result!==expected) $fatal(1,"restart result not held until consumption");
            end
            // Existing consume priority remains intact even if a new start is
            // asserted while done. It must consume, not launch another operation.
            consume=1;start=1;tick();consume=0;start=0;
            if(busy||done) $fatal(1,"consume/start collision launched a second operation");
            tick();if(busy||done) $fatal(1,"consumed operation resurfaced");
            restarts=restarts+1;
        end
    endtask
    task automatic cancel_position(input integer op_index,input integer position);
        integer cycle,n;
        begin
            instr_id=operations[op_index];lhs=32'h87654321;
            // Divider start+cancel also exercises its immediate divide-by-zero
            // result path, where cancellation must override a new done token.
            rhs=(position==0&&op_index>=4) ? 32'b0 : 32'h12345;
            start=1;cancel=(position==0);consume=0;
            tick();start=0;
            if(position>0) begin
                if(!busy||done) $fatal(1,"initial operation did not start");
                for(cycle=1;cycle<position;cycle=cycle+1) begin
                    tick();
                    if(!busy||done) $fatal(1,"operation completed before cancel position %0d",position);
                end
                // Include cancel+start, cancel+consume, and all three asserted.
                // Cancellation must dominate even on the last busy iteration.
                cancel=1;start=position[0];consume=position[1];
                instr_id=operations[(op_index+3)%8];lhs=32'hdeadbeef;rhs=0;
                tick();
            end
            canceled_state();cancel=0;start=0;consume=0;
            // Some replacements start immediately. Other cases wait beyond an
            // entire divide latency to expose a private datapath still running.
            n=(position%3==0) ? 0 : (position%3==1) ? 1 : 35;
            repeat(n) begin tick();canceled_state();end
            restart_check((op_index+position+1)%8,op_index+position);
            cancellations=cancellations+1;
        end
    endtask
    task automatic cancel_held_result(input integer op_index,input integer pattern);
        reg [31:0] expected;
        integer cycles,n;
        begin
            instr_id=operations[op_index];lhs=pattern[0] ? 32'h80000000 : 32'habcd4321;
            rhs=pattern[0] ? 32'hffffffff : 0;expected=arithmetic(instr_id,lhs,rhs);
            start=1;tick();start=0;cycles=0;
            while(!done&&cycles<40) begin tick();cycles=cycles+1;end
            if(!done||result!==expected) $fatal(1,"held-result fixture arithmetic mismatch");
            n=pattern==0 ? 0 : pattern==1 ? 1 : 5;
            repeat(n) begin tick();if(!done||result!==expected) $fatal(1,"fixture result lost before cancel");end
            cancel=1;start=pattern[0];consume=pattern[1];
            instr_id=operations[(op_index+5)%8];lhs=32'h11111111;rhs=32'h22222222;
            tick();canceled_state();cancel=0;start=0;consume=0;
            restart_check((op_index+pattern+1)%8,op_index+pattern+1);
            cancellations=cancellations+1;
        end
    endtask
    integer op,position,latency,pattern;
    initial begin
        operations[0]=INSTR_MUL;operations[1]=INSTR_MULH;operations[2]=INSTR_MULHSU;operations[3]=INSTR_MULHU;
        operations[4]=INSTR_DIV;operations[5]=INSTR_DIVU;operations[6]=INSTR_REM;operations[7]=INSTR_REMU;
        repeat(3) tick();rst=0;
        for(op=0;op<8;op=op+1) begin
            latency=(FAST_MULTIPLY&&op<4) ? 2 : 32;
            // Position zero is cancel+start; position latency cancels the edge
            // that would otherwise publish the result. Every busy edge is hit.
            for(position=0;position<=latency;position=position+1) cancel_position(op,position);
            for(pattern=0;pattern<4;pattern=pattern+1) cancel_held_result(op,pattern);
        end
        if(cancellations!=restarts) $fatal(1,"missing restart validation");
        $display("PASS: muldiv cancellation fast=%0d cancel_positions=%0d verified_restarts=%0d; all8ops/everybusyedge, held done, cancel+start+consume, stale-result exclusion, div0/overflow replacements",FAST_MULTIPLY,cancellations,restarts);
        $finish;
    end
    initial begin #10000000;$fatal(1,"global timeout");end
endmodule
