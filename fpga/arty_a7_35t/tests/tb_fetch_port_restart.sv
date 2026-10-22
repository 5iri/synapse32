`timescale 1ns/1ps
`default_nettype none
// Exercise registered frontend cancellation through public transaction pins.
// A restart may accept a fresh request on the cancellation edge, but an old
// granted lower transaction must retain ownership until its response drains.
module tb_fetch_port_restart;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg flush_tlb=0,fetch_cancel=0,req=0,translate=0;
    reg [31:0] va=32'h80000000,satp=0;
    reg [1:0] privilege=3;
    wire gnt,rvalid,page_fault,access_fault,fatal_error,bus_req,bus_we,bus_fetch;
    wire [31:0] rdata,bus_addr,bus_wdata;
    wire [3:0] bus_be;
    reg bus_gnt=0,bus_done=0,bus_error=0;
    reg [31:0] bus_rdata=0;
    reg [127:0] bus_line=0;
    integer responses=0,bus_accepts=0,cases=0;
    reg returned_token=0,returned_page_fault=0,returned_access_fault=0;
    reg [31:0] returned_data=0;
    localparam [31:0] A=32'h80000000,B=32'h80000010,C=32'h80000040;
    localparam [31:0] V0=32'h40000000,V1=32'h40001000;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(16),.PIPELINED_FETCH(1),.RESTART_ON_CANCEL(1)) dut (
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
        if(rvalid) responses=responses+1;
        if(bus_req&&bus_gnt) bus_accepts=bus_accepts+1;
        if(fetch_cancel&&rvalid) $fatal(1,"canceled response escaped on restart edge");
        if(page_fault&&access_fault) $fatal(1,"overlapping response faults");
        if(fatal_error||bus_we) $fatal(1,"instruction port became fatal or issued a write");
    end
    function automatic [31:0] word_at(input [31:0] address);
        word_at=32'ha5000000^address;
    endfunction
    task automatic tick;
        begin @(posedge clk);#1;@(negedge clk);end
    endtask
    task automatic reset_port;
        begin
            if(returned_token) $fatal(1,"reset discarded an unchecked response");
            rst=1;req=0;fetch_cancel=0;flush_tlb=0;translate=0;satp=0;privilege=3;
            bus_gnt=0;bus_done=0;bus_error=0;
            tick();tick();rst=0;tick();
        end
    endtask
    task automatic issue(input [31:0] address);
        integer n;
        begin
            if(returned_token) $fatal(1,"new request before checking completed response");
            req=1;va=address;#1;n=0;
            while(!gnt&&n<50) begin tick();n=n+1;end
            if(!gnt) $fatal(1,"grant timeout at %h",address);
            tick();req=0;va=address+4;
        end
    endtask
    task automatic expect_bus(input [31:0] address,input bit fetch=1);
        integer n;
        begin
            #1;n=0;
            while(!bus_req&&n<50) begin
                if(rvalid) $fatal(1,"unexpected cached response when expecting bus %h",address);
                tick();n=n+1;
            end
            if(!bus_req||bus_addr!==address||bus_fetch!==fetch)
                $fatal(1,"bus got req=%b addr=%h fetch=%b expected %h fetch=%b",bus_req,bus_addr,bus_fetch,address,fetch);
        end
    endtask
    task automatic grant_bus(input [31:0] address,input bit fetch=1);
        begin expect_bus(address,fetch);bus_gnt=1;tick();bus_gnt=0;end
    endtask
    task automatic return_bus(input [31:0] address,input [31:0] value,input bit error=0);
        integer n;
        begin
            for(n=0;n<4;n=n+1) bus_line[n*32+:32]=word_at((address&32'hfffffff0)+32'(n*4));
            if(returned_token) $fatal(1,"lower return overwrote an unchecked response");
            bus_rdata=value;bus_error=error;bus_done=1;#1;
            if(rvalid) begin
                returned_token=1;returned_data=rdata;
                returned_page_fault=page_fault;returned_access_fault=access_fault;
            end
            tick();bus_done=0;bus_error=0;
        end
    endtask
    task automatic response(input [31:0] expected);
        integer n;
        begin
            #1;n=0;
            if(returned_token) begin
                if(returned_data!==expected||returned_page_fault||returned_access_fault)
                    $fatal(1,"completed response data=%h pf=%b af=%b expected %h",
                           returned_data,returned_page_fault,returned_access_fault,expected);
                returned_token=0;
                if(rvalid) $fatal(1,"completed response was replayed");
                tick();
            end else begin
                while(!rvalid&&n<50) begin
                    if(bus_req) $fatal(1,"unexpected lower transaction while awaiting hit");
                    tick();n=n+1;
                end
                if(!rvalid||rdata!==expected||page_fault||access_fault)
                    $fatal(1,"response got valid=%b data=%h pf=%b af=%b expected %h",rvalid,rdata,page_fault,access_fault,expected);
                tick();
            end
        end
    endtask
    task automatic fill_line(input [31:0] address);
        begin issue(address);grant_bus(address);return_bus(address,word_at(address));response(word_at(address));end
    endtask
    task automatic warm;
        begin reset_port();fill_line(A);fill_line(B);end
    endtask
    task automatic restart_hit(input [31:0] address,input [31:0] expected);
        begin
            req=1;va=address;fetch_cancel=1;#1;
            if(!gnt||rvalid) $fatal(1,"restart did not accept fresh target %h",address);
            tick();req=0;fetch_cancel=0;va=address+4;
            response(expected);cases=cases+1;
        end
    endtask
    task automatic assert_uncached(input [31:0] address);
        begin issue(address);grant_bus(address);return_bus(address,word_at(address));response(word_at(address));end
    endtask
    task automatic assert_cached(input [31:0] address);
        integer before_bus;
        begin
            before_bus=bus_accepts;issue(address);response(word_at(address));
            if(bus_req||bus_accepts!=before_bus)
                $fatal(1,"canceled successful RAM read did not retain physical line %h",address);
        end
    endtask
    task automatic warm_translation;
        begin
            warm();translate=1;privilege=0;satp=32'h80080001;tick();tick();
            issue(V0);grant_bus(32'h80001400,0);return_bus(32'h80001400,32'h20000801);
            grant_bus(32'h80002000,0);return_bus(32'h80002000,32'h2000005b);
            response(word_at(A));
        end
    endtask

    integer error,before_responses,before_bus;
    initial begin
        @(negedge clk);
        // A target can replace idle work, a returning hit, a cache miss before
        // its request, an ungranted access, and a completed read.
        warm();restart_hit(A,word_at(A));
        issue(A);restart_hit(B,word_at(B));
        issue(C);restart_hit(A,word_at(A));
        issue(C);expect_bus(C);restart_hit(B,word_at(B));
        issue(C);grant_bus(C);return_bus(C,word_at(C));response(word_at(C));restart_hit(A,word_at(A));

        // The new target itself can miss or fault. Its fresh response class
        // must replace the canceled hit/fault payload precisely.
        warm();issue(A);req=1;va=C;fetch_cancel=1;#1;
        if(!gnt||rvalid) $fatal(1,"cold restart target not accepted");
        tick();req=0;fetch_cancel=0;va=C+4;
        grant_bus(C);return_bus(C,word_at(C));response(word_at(C));cases=cases+1;
        issue(A);req=1;va=32'h20000000;fetch_cancel=1;#1;
        if(!gnt||rvalid) $fatal(1,"MMIO restart target not accepted");
        tick();req=0;fetch_cancel=0;#1;
        if(!rvalid||!access_fault||page_fault||rdata!==32'h13||bus_req)
            $fatal(1,"MMIO restart did not produce a precise access-fault token");
        tick();cases=cases+1;
        issue(32'h20000000);restart_hit(A,word_at(A));

        // Cancellation during WAIT may restart on the actual completion edge.
        // The abandoned CPU token never escapes. A successful normal RAM
        // completion still warms C; a failed completion never allocates it.
        for(error=0;error<2;error=error+1) begin
            warm();issue(C);grant_bus(C);before_responses=responses;
            req=1;va=A;fetch_cancel=1;bus_done=1;bus_error=1'(error);
            bus_rdata=word_at(C);bus_line={4{word_at(C)}};#1;
            if(!gnt||rvalid) $fatal(1,"completion/cancel did not restart error=%0d",error);
            tick();req=0;fetch_cancel=0;bus_done=0;bus_error=0;va=A+4;
            response(word_at(A));
            if(responses!=before_responses+1) $fatal(1,"abandoned WAIT response delivered");
            if(error) assert_uncached(C);else assert_cached(C);
            cases=cases+1;
        end

        // A registered cancellation reaches the port before an old ungranted
        // read is accepted. Even an available lower bus must not take that
        // unnecessary request and delay the fresh warmed target.
        for(error=0;error<2;error=error+1) begin
            warm();issue(C);expect_bus(C);before_bus=bus_accepts;before_responses=responses;
            req=1;va=error ? B : A;fetch_cancel=1;bus_gnt=1;#1;
            if(!gnt||bus_req||rvalid) $fatal(1,"registered cancel launched an unnecessary old lower read instead of restarting");
            tick();req=0;fetch_cancel=0;bus_gnt=0;va=(error ? B : A)+4;
            response(word_at(error ? B : A));
            if(bus_accepts!=before_bus||responses!=before_responses+1)
                $fatal(1,"registered cancel consumed lower bandwidth or leaked a response");
            assert_uncached(C);cases=cases+1;
        end

        // A cancel before completion likewise blocks new work while the
        // already-granted old read is still outstanding.
        warm();issue(C);grant_bus(C);req=1;va=B;fetch_cancel=1;#1;
        if(gnt||rvalid) $fatal(1,"WAIT restarted without completion");
        tick();fetch_cancel=0;tick();
        if(gnt||rvalid) $fatal(1,"canceled WAIT accepted target early");
        return_bus(C,word_at(C));#1;if(!gnt||rvalid) $fatal(1,"drain did not release target");
        tick();req=0;va=B+4;response(word_at(B));assert_cached(C);cases=cases+1;

        // Repeated registered cancellations replace their preceding target;
        // only the final target produces an architectural response.
        warm();issue(C);before_responses=responses;
        req=1;va=A;fetch_cancel=1;#1;if(!gnt||rvalid) $fatal(1,"first consecutive restart");
        tick();va=B;#1;if(!gnt||rvalid) $fatal(1,"second consecutive restart");
        tick();req=0;fetch_cancel=0;va=B+4;response(word_at(B));
        if(responses!=before_responses+1) $fatal(1,"consecutive restart leaked old target");
        cases=cases+1;

        // A simultaneous instruction TLB flush intentionally blocks restart;
        // the next eligible cycle can accept the request normally.
        warm();req=1;va=A;fetch_cancel=1;flush_tlb=1;#1;
        if(gnt||rvalid) $fatal(1,"restart bypassed TLB invalidation");
        tick();fetch_cancel=0;flush_tlb=0;#1;if(!gnt) $fatal(1,"request blocked after flush");
        tick();req=0;va=A+4;response(word_at(A));cases=cases+1;

        // A leaf returned on the cancellation/restart edge must not refill the
        // TLB. V0's existing translation permits an immediate warm target.
        for(error=0;error<2;error=error+1) begin
            warm_translation();issue(V1);
            grant_bus(32'h80001400,0);return_bus(32'h80001400,32'h20000801);
            grant_bus(32'h80002004,0);before_responses=responses;
            req=1;va=V0;fetch_cancel=1;bus_done=1;bus_error=1'(error);bus_rdata=32'h2000105b;#1;
            if(!gnt||rvalid) $fatal(1,"PTE completion did not restart error=%0d",error);
            tick();req=0;fetch_cancel=0;bus_done=0;bus_error=0;va=V0+4;
            response(word_at(A));
            if(responses!=before_responses+1) $fatal(1,"canceled PTE response escaped");
            issue(V1);grant_bus(32'h80001400,0);return_bus(32'h80001400,32'h20000801);
            grant_bus(32'h80002004,0);return_bus(32'h80002004,32'h2000105b);
            grant_bus(32'h80004000);return_bus(32'h80004000,word_at(32'h80004000));
            response(word_at(32'h80004000));cases=cases+1;
        end

        // The walked old transaction has reached its cache-request slot.
        // Restart must look up the new physical target, not old bus_addr.
        warm_translation();issue(V1);
        grant_bus(32'h80001400,0);return_bus(32'h80001400,32'h20000801);
        grant_bus(32'h80002004,0);return_bus(32'h80002004,32'h2000105b);
        restart_hit(V0,word_at(A));

        // A warm U-only TLB entry is a page fault for the fresh S-mode target;
        // restarting must recheck permissions rather than return cached data.
        warm_translation();issue(V0);privilege=1;
        req=1;va=V0;fetch_cancel=1;#1;
        if(!gnt||rvalid) $fatal(1,"permission-fault restart target not accepted");
        tick();req=0;fetch_cancel=0;#1;
        if(!rvalid||!page_fault||access_fault||rdata!==32'h13||bus_req)
            $fatal(1,"restart bypassed fresh-target TLB permissions");
        tick();cases=cases+1;

        // Registered cancellation also suppresses an ungranted page-table
        // request, allowing the existing TLB-hit target to restart immediately.
        warm_translation();issue(V1);expect_bus(32'h80001400,0);before_bus=bus_accepts;
        req=1;va=V0;fetch_cancel=1;bus_gnt=1;#1;
        if(!gnt||bus_req||rvalid) $fatal(1,"registered cancel launched an unnecessary page-table read");
        tick();req=0;bus_gnt=0;fetch_cancel=0;va=V0+4;response(word_at(A));
        if(bus_accepts!=before_bus) $fatal(1,"canceled page-table request consumed lower bandwidth");
        cases=cases+1;

        if(returned_token) $fatal(1,"unchecked completed response at test end");
        $display("PASS: fetch port registered restart %0d cases, warm targets, misses, DONE, completion errors, old-grant drains and canceled TLB fills",cases);
        $finish;
    end
    initial begin #2000000;$fatal(1,"global timeout");end
endmodule
