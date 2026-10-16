`timescale 1ns/1ps
`default_nettype none
module tb_instruction_fetch_queue;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg consume=0,redirect=0,flush_tlb=0,translate=0;
    reg [31:0] cpu_pc=32'h80000000,redirect_pc=0,satp=0;
    reg [1:0] privilege=3;
    wire valid,page_fault,access_fault,req,cancel;
    wire [31:0] instruction,head_pc,request_pc;
    reg gnt=0,rvalid=0,response_page_fault=0,response_access_fault=0;
    reg [31:0] response_data=0;
    instruction_fetch_queue dut(.*);
    task automatic cycle(input bit grant,input bit reply,input bit pop,
                         input [31:0] word_value=0,input bit pf=0,input bit af=0);
        begin
            gnt=grant;rvalid=reply;consume=pop;response_data=word_value;
            response_page_fault=pf;response_access_fault=af;
            #1;
            if(pop) begin
                if(!valid) $fatal(1,"test attempted consume without valid");
                cpu_pc=head_pc;
            end
            if(grant&&!req) $fatal(1,"test granted without request");
            @(negedge clk);gnt=0;rvalid=0;consume=0;
            response_page_fault=0;response_access_fault=0;
            #1;
        end
    endtask
    task automatic head(input [31:0] pc,input [31:0] word_value,input bit pf=0,input bit af=0);
        begin
            #1;
            if(!valid||head_pc!==pc||instruction!==word_value||page_fault!==pf||access_fault!==af)
                $fatal(1,"head got valid=%b pc=%h word=%h pf=%b af=%b expected pc=%h word=%h pf=%b af=%b",
                       valid,head_pc,instruction,page_fault,access_fault,pc,word_value,pf,af);
        end
    endtask
    task automatic reset_queue;
        begin
            @(negedge clk);rst=1;gnt=0;rvalid=0;consume=0;redirect=0;flush_tlb=0;
            translate=0;privilege=3;satp=0;cpu_pc=32'h80000000;
            repeat(2) @(negedge clk);rst=0;#1;
        end
    endtask
    reg held=0;
    reg [31:0] held_pc,held_word;
    reg held_pf,held_af;
    always @(posedge clk) begin
        if(rst||cancel) held<=0;
        else begin
            if(held&&(!valid||head_pc!==held_pc||instruction!==held_word||
                      page_fault!==held_pf||access_fault!==held_af))
                $fatal(1,"stalled head changed without consume/cancel");
            held<=valid&&!consume;
            held_pc<=head_pc;held_word<=instruction;held_pf<=page_fault;held_af<=access_fault;
        end
    end
    initial begin
        reset_queue();
        if(!req||request_pc!=32'h80000000) $fatal(1,"reset fetch PC");
        cycle(1,0,0);
        cycle(1,1,0,32'ha0000000);
        head(32'h80000000,32'ha0000000);
        // A response, head consume and next request may all occur together.
        cycle(1,1,1,32'hb0000004);
        head(32'h80000004,32'hb0000004);
        cycle(1,1,0,32'hc0000008);
        cycle(1,1,0,32'hd000000c);
        if(req) $fatal(1,"three queued plus pending request exhausted credits");
        cycle(0,1,0,32'he0000010);
        if(req) $fatal(1,"full queue accepted another request");
        repeat(4) begin cycle(0,0,0);head(32'h80000004,32'hb0000004);end
        cycle(0,0,1);
        head(32'h80000008,32'hc0000008);
        if(!req) $fatal(1,"credit did not return after head consumed");
        cycle(1,0,1);
        head(32'h8000000c,32'hd000000c);
        cycle(1,1,1,32'hf0000014);
        head(32'h80000010,32'he0000010);
        // A redirect to the SAME architectural PC is still a cancellation.
        cpu_pc=32'h80000010;redirect_pc=cpu_pc;redirect=1;rvalid=1;
        response_data=32'hbadbad00;response_page_fault=1;
        #1;if(!cancel||valid||req) $fatal(1,"same-PC redirect did not hide old head/reply");
        @(negedge clk);redirect=0;rvalid=0;response_page_fault=0;#1;
        if(valid||!req||request_pc!=32'h80000010) $fatal(1,"same-PC redirect restart");
        // Canceled replies before the fresh request cannot become fault tokens.
        cycle(0,1,0,32'hbadbad01,1,1);
        if(valid||!req) $fatal(1,"late canceled response survived");
        cycle(1,0,0);
        cycle(0,1,0,32'h11111110);
        head(32'h80000010,32'h11111110);
        cycle(1,0,0);
        cycle(0,1,0,32'hdead0014,1,0);
        head(32'h80000010,32'h11111110);
        if(req) $fatal(1,"speculation continued after a page-fault response");
        cycle(0,0,1);
        head(32'h80000014,32'hdead0014,1,0);
        // A context switch drops queued faults and restarts at cpu_pc.
        cpu_pc=32'h80002000;translate=1;privilege=0;satp=32'h80080001;
        #1;if(!cancel||valid||page_fault) $fatal(1,"context change exposed wrong-path fault");
        @(negedge clk);#1;
        if(!req||request_pc!=cpu_pc||valid) $fatal(1,"context restart PC");
        cycle(1,0,0);
        cycle(0,1,0,32'hdead2000,0,1);
        head(32'h80002000,32'hdead2000,0,1);
        flush_tlb=1;#1;
        if(!cancel||valid||access_fault) $fatal(1,"SFENCE cancellation exposed access fault");
        @(negedge clk);flush_tlb=0;#1;
        cycle(1,0,0);
        cycle(0,1,0,32'h22222000);
        head(32'h80002000,32'h22222000);
        cycle(0,0,1);
        if(valid) $fatal(1,"consumed final head remained valid");
        // Empty-queue fall-through can be consumed directly, without a duplicate.
        cycle(1,0,0);
        cycle(0,1,1,32'h33332004);
        if(valid||dut.count!=0||dut.pending) $fatal(1,"bypassed response was also enqueued");
        $display("PASS fetch queue: credit/full backpressure, push/pop/grant, same-PC redirect, canceled reply, context/fault flush, empty bypass");
        $finish;
    end
    initial begin #10000;$fatal(1,"global timeout");end
endmodule
