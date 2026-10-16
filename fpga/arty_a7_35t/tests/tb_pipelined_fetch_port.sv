`timescale 1ns/1ps
`default_nettype none
module tb_pipelined_fetch_port;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg flush_tlb=0, fetch_cancel=0, req=0, translate=0;
    reg [31:0] va=32'h80000000, satp=0;
    reg [1:0] privilege=3;
    wire gnt,rvalid,page_fault,access_fault,fatal_error,bus_req,bus_we,bus_fetch;
    wire [31:0] rdata,bus_addr,bus_wdata;
    wire [3:0] bus_be;
    reg bus_gnt=0,bus_done=0,bus_error=0;
    reg [31:0] bus_rdata=0;
    reg [127:0] bus_line=0;
    integer accepted=0,responses=0,bus_accepts=0;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(16),.PIPELINED_FETCH(1)) dut (
        .clk(clk),.rst(rst),.flush_tlb(flush_tlb),.fetch_cancel(fetch_cancel),
        .req(req),.we(1'b0),.write_intent(1'b0),.translate(translate),
        .va(va),.satp(satp),.wdata(32'b0),.privilege(privilege),
        .sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'd2),
        .gnt(gnt),.rvalid(rvalid),.page_fault(page_fault),.access_fault(access_fault),.rdata(rdata),
        .bus_req(bus_req),.bus_we(bus_we),.bus_fetch(bus_fetch),.bus_addr(bus_addr),
        .bus_wdata(bus_wdata),.bus_be(bus_be),.bus_gnt(bus_gnt),.bus_done(bus_done),
        .bus_rdata(bus_rdata),.bus_line(bus_line),.bus_error(bus_error),
        .snoop(1'b0),.snoop_addr(32'b0),.snoop_data(32'b0),.snoop_be(4'b0),.snoop_error(1'b0),
        .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),.fatal_error(fatal_error)
    );
    always @(posedge clk) if(!rst) begin
        if(gnt) accepted=accepted+1;
        if(rvalid) responses=responses+1;
        if(bus_req&&bus_gnt) bus_accepts=bus_accepts+1;
        if(fatal_error) $fatal(1,"speculative access raised fatal_error");
        if(page_fault&&access_fault) $fatal(1,"fault classifications overlap");
        if(fetch_cancel&&(gnt||rvalid)) $fatal(1,"canceled request/response escaped");
        if(bus_req&&!((bus_addr>=32'h80000000&&bus_addr<=32'h83ffffff)||
                      (bus_addr>=32'h10000000&&bus_addr<=32'h100fffff)))
            $fatal(1,"instruction lower-bus request addressed non-RAM");
    end
    function automatic [31:0] word_at(input [31:0] address);
        word_at=32'ha5000000^address;
    endfunction
    task automatic tick;
        begin @(posedge clk); #1; @(negedge clk); end
    endtask
    task automatic idle_context(input bit translated,input [31:0] root,input [1:0] priv);
        begin
            req=0;fetch_cancel=1;tick();fetch_cancel=0;
            translate=translated;satp=root;privilege=priv;tick();tick();
        end
    endtask
    task automatic wait_state(input integer expected);
        integer n;
        begin
            n=0;#1;
            while(dut.state!=3'(expected)&&n<40) begin tick();n=n+1;end
            if(dut.state!=3'(expected)) $fatal(1,"state %0d not reached, got %0d",expected,dut.state);
        end
    endtask
    task automatic issue(input [31:0] address);
        integer n;
        begin
            req=1;va=address;#1;n=0;
            while(!gnt&&n<40) begin tick();n=n+1;end
            if(!gnt) $fatal(1,"request grant timeout");
            tick();req=0;
            // Advancing the next request must not stale the response.
            va=address+4;#1;
        end
    endtask
    task automatic grant_bus(input [31:0] expected);
        begin
            #1;
            while(!bus_req) tick();
            if(bus_addr!==expected) $fatal(1,"bus address %h expected %h",bus_addr,expected);
            bus_gnt=1;tick();bus_gnt=0;
            if(bus_req) $fatal(1,"request repeated after grant");
        end
    endtask
    task automatic respond_bus(input [31:0] address,input [31:0] value,input bit error=0);
        integer n;
        begin
            for(n=0;n<4;n=n+1) bus_line[n*32+:32]=word_at((address&32'hfffffff0)+32'(n*4));
            bus_rdata=value;bus_error=error;bus_done=1;tick();bus_done=0;bus_error=0;#1;
        end
    endtask
    task automatic response(input [31:0] expected,input bit pf=0,input bit af=0);
        integer n;
        begin
            n=0;#1;
            while(!rvalid&&n<40) begin tick();n=n+1;end
            if(!rvalid||page_fault!==pf||access_fault!==af)
                $fatal(1,"response fault mismatch valid=%b pf=%b af=%b",rvalid,page_fault,access_fault);
            if(rdata!==expected) $fatal(1,"response %h expected %h",rdata,expected);
            tick();
        end
    endtask
    task automatic cancel_now;
        integer before_count;
        begin
            before_count=responses;fetch_cancel=1;#1;
            if(rvalid||gnt) $fatal(1,"cancel not combinational");
            tick();fetch_cancel=0;#1;
            if(responses!=before_count) $fatal(1,"canceled token delivered");
        end
    endtask
    task automatic cancel_with_grant(input [31:0] address,input integer wait_stage,
                                     input bit use_tlb_flush=0,input bit returned_error=1);
        integer before_count,before_grants;
        begin
            before_count=responses;before_grants=bus_accepts;
            fetch_cancel=!use_tlb_flush;flush_tlb=use_tlb_flush;bus_gnt=1;#1;
            if(!bus_req||bus_addr!==address) $fatal(1,"late cancel changed registered RAM request");
            if(gnt||rvalid) $fatal(1,"cancel allowed a frontend handshake");
            tick();bus_gnt=0;fetch_cancel=0;flush_tlb=0;#1;
            if(dut.state!=3'(wait_stage)||bus_accepts!=before_grants+1)
                $fatal(1,"cancel/grant collision did not retain lower transaction");
            req=1;va=32'h80000000;#1;
            if(gnt||rvalid||bus_req) $fatal(1,"new work accepted before canceled read drained");
            tick();tick();
            respond_bus(address,word_at(address),returned_error);req=0;#1;
            if(responses!=before_count||rvalid||fatal_error)
                $fatal(1,"canceled grant returned a fault/response");
            wait_state(0);
        end
    endtask
    task automatic fill_line(input [31:0] address);
        begin issue(address);grant_bus(address);respond_bus(address,word_at(address));response(word_at(address));end
    endtask
    task automatic root_pte;
        begin grant_bus(32'h80001400);respond_bus(32'h80001400,32'h20000801);end
    endtask
    task automatic leaf_pte(input [31:0] pte);
        begin grant_bus(32'h80002000);respond_bus(32'h80002000,pte);end
    endtask
    task automatic flush_context;
        begin flush_tlb=1;fetch_cancel=1;tick();flush_tlb=0;fetch_cancel=0;tick();end
    endtask

    integer n,before_responses,before_bus;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        fill_line(32'h80000000);fill_line(32'h80000010);
        // Eight warmed instructions return on eight consecutive clocks while
        // the next independent request PC advances on every cycle.
        before_responses=responses;before_bus=bus_accepts;
        req=1;va=32'h80000000;#1;if(!gnt) $fatal(1,"initial burst grant");tick();
        for(n=1;n<8;n=n+1) begin
            va=32'h80000000+32'(4*n);#1;
            if(!gnt||!rvalid||rdata!==word_at(va-4)||bus_req) $fatal(1,"burst bubble at %0d",n);
            tick();
        end
        req=0;#1;if(!rvalid||rdata!==word_at(32'h8000001c)) $fatal(1,"last burst response");tick();
        if(responses!=before_responses+8||bus_accepts!=before_bus) $fatal(1,"burst accounting");

        // A hit may hand over directly to a miss, then the miss blocks grants.
        issue(32'h80000000);req=1;va=32'h80000040;#1;
        if(!gnt||!rvalid) $fatal(1,"hit to miss handover");tick();req=0;
        if(gnt||rvalid) $fatal(1,"miss was prematurely acknowledged");
        grant_bus(32'h80000040);tick();tick();respond_bus(32'h80000040,word_at(32'h80000040));response(word_at(32'h80000040));

        // No untranslated, TLB-hit or walked fetch may read MMIO speculatively.
        before_bus=bus_accepts;
        issue(32'h20000000);response(32'h13,0,1);
        issue(32'h0c000000);response(32'h13,0,1);
        if(bus_accepts!=before_bus) $fatal(1,"MMIO fetch reached physical bus");
        idle_context(1,32'h80080001,0);
        issue(32'h40000000);root_pte();leaf_pte(32'h2000005b);response(word_at(32'h80000000));
        issue(32'h40000004);response(word_at(32'h80000004));
        // Permission checks apply even to a resident TLB/L1 hit. Fault tokens
        // must carry NOP, never a previous CSR/MRET instruction payload.
        privilege=1;tick();issue(32'h40000004);response(32'h13,1,0);privilege=0;tick();
        flush_context();issue(32'h40000000);root_pte();leaf_pte(32'h0800005b);response(32'h13,0,1);
        before_bus=bus_accepts;issue(32'h40000004);response(32'h13,0,1);
        if(bus_accepts!=before_bus) $fatal(1,"TLB MMIO hit reached bus");
        idle_context(1,32'h80020000,0);issue(32'h40000000);response(32'h13,0,1);

        // Granted instruction and page-table read errors become precise tokens.
        idle_context(0,0,3);issue(32'h80000080);grant_bus(32'h80000080);
        respond_bus(32'h80000080,0,1);response(32'h13,0,1);
        idle_context(1,32'h80080001,0);flush_context();issue(32'h40000000);
        grant_bus(32'h80001400);respond_bus(32'h80001400,0,1);response(32'h13,0,1);
        issue(32'h40000000);root_pte();grant_bus(32'h80002000);
        respond_bus(32'h80002000,0,1);response(32'h13,0,1);

        // Cancel a queued hit and each non-granted slow stage.
        idle_context(0,0,3);issue(32'h80000000);cancel_now();wait_state(0);
        issue(32'h80000090);wait_state(6);cancel_now();wait_state(0);
        issue(32'h80000090);wait_state(3);cancel_now();wait_state(0);
        idle_context(1,32'h80080001,0);flush_context();issue(32'h40000000);wait_state(1);cancel_now();wait_state(0);

        // Cancellation no longer gates the lower request combinationally. If
        // arbitration grants at that edge, preserve ownership until response.
        idle_context(0,0,3);issue(32'h800000d0);wait_state(3);
        cancel_with_grant(32'h800000d0,4);
        issue(32'h800000e0);wait_state(3);cancel_with_grant(32'h800000e0,4,0,0);
        issue(32'h800000e0);
        if(rvalid) $fatal(1,"canceled successful read allocated an instruction cache line");
        grant_bus(32'h800000e0);respond_bus(32'h800000e0,word_at(32'h800000e0));response(word_at(32'h800000e0));
        idle_context(1,32'h80080001,0);flush_context();issue(32'h40000000);wait_state(1);
        cancel_with_grant(32'h80001400,2);
        issue(32'h40000000);wait_state(1);cancel_with_grant(32'h80001400,2,1);

        // A canceled granted read must drain before any new grant, and an error
        // arriving at the cancel edge must neither fault nor leave a cache fill.
        idle_context(0,0,3);issue(32'h800000a0);grant_bus(32'h800000a0);cancel_now();
        req=1;va=32'h80000000;#1;if(gnt) $fatal(1,"new grant before canceled read drained");req=0;
        respond_bus(32'h800000a0,0,1);wait_state(0);
        issue(32'h800000a0);grant_bus(32'h800000a0);respond_bus(32'h800000a0,word_at(32'h800000a0));response(word_at(32'h800000a0));
        issue(32'h800000b0);grant_bus(32'h800000b0);fetch_cancel=1;
        respond_bus(32'h800000b0,0,1);fetch_cancel=0;wait_state(0);

        // Cancel first- and second-level page reads, including leaf-return
        // collision. A canceled leaf must not populate the TLB.
        idle_context(1,32'h80080001,0);flush_context();issue(32'h40000000);
        grant_bus(32'h80001400);cancel_now();respond_bus(32'h80001400,32'h20000801);wait_state(0);
        issue(32'h40000000);root_pte();grant_bus(32'h80002000);fetch_cancel=1;
        respond_bus(32'h80002000,32'h2000005b);fetch_cancel=0;wait_state(0);
        issue(32'h40000000);root_pte();leaf_pte(32'h2000005b);wait_state(7);cancel_now();wait_state(0);
        issue(32'h40000000);response(word_at(32'h80000000));

        // A flush/context change cancels a slow response even without an
        // explicit cancel pulse; the next context can issue once it drains.
        flush_context();issue(32'h40000000);grant_bus(32'h80001400);
        satp=32'h80480001;tick();respond_bus(32'h80001400,32'h20000801);wait_state(0);
        idle_context(0,0,3);issue(32'h800000c0);grant_bus(32'h800000c0);
        respond_bus(32'h800000c0,word_at(32'h800000c0));wait_state(5);cancel_now();wait_state(0);
        issue(32'h80000000);response(word_at(32'h80000000));
        $display("PASS: pipelined fetch hits, misses, walks, permissions, precise access faults, MMIO rejection and cancellation");
        $finish;
    end
    initial begin #1000000;$fatal(1,"global timeout");end
endmodule
