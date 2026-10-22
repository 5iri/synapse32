`timescale 1ns/1ps
`default_nettype none
// Public-port regression for the registered instruction-cache write stream.
// The lower bus serializes fills and stores, but a posted store can arrive on
// the cycle immediately after an instruction fill. Both operations must survive.
module tb_frontend_cache_transactions;
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
    reg snoop=0,snoop_error=0;
    reg [31:0] snoop_addr=0,snoop_data=0;
    reg [3:0] snoop_be=0;
    integer responses=0,bus_accepts=0,cases=0;
    reg returned_token=0,returned_page_fault=0,returned_access_fault=0;
    reg [31:0] returned_data=0;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(4),.PIPELINED_FETCH(1)) dut (
        .clk(clk),.rst(rst),.flush_tlb(flush_tlb),.fetch_cancel(fetch_cancel),
        .req(req),.we(1'b0),.write_intent(1'b0),.translate(translate),
        .va(va),.satp(satp),.wdata(32'b0),.privilege(privilege),
        .sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'd2),
        .gnt(gnt),.rvalid(rvalid),.page_fault(page_fault),.access_fault(access_fault),.rdata(rdata),
        .bus_req(bus_req),.bus_we(bus_we),.bus_fetch(bus_fetch),.bus_addr(bus_addr),
        .bus_wdata(bus_wdata),.bus_be(bus_be),.bus_gnt(bus_gnt),.bus_done(bus_done),
        .bus_rdata(bus_rdata),.bus_line(bus_line),.bus_error(bus_error),
        .snoop(snoop),.snoop_addr(snoop_addr),.snoop_data(snoop_data),.snoop_be(snoop_be),.snoop_error(snoop_error),
        .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),.fatal_error(fatal_error)
    );
    always @(posedge clk) if(!rst) begin
        if(rvalid) responses=responses+1;
        if(bus_req&&bus_gnt) bus_accepts=bus_accepts+1;
        if(fatal_error) $fatal(1,"speculative instruction operation raised fatal error");
        if(fetch_cancel&&(gnt||rvalid)) $fatal(1,"redirect exposed a handshake");
        if(page_fault&&access_fault) $fatal(1,"overlapping fault classes");
        if(bus_we) $fatal(1,"instruction port issued write");
    end
    task automatic tick;
        begin @(posedge clk);#1;@(negedge clk);end
    endtask
    task automatic reset_port;
        begin
            if(returned_token) $fatal(1,"reset discarded an unchecked response");
            rst=1;req=0;flush_tlb=0;fetch_cancel=0;translate=0;satp=0;privilege=3;
            bus_gnt=0;bus_done=0;bus_error=0;snoop=0;snoop_error=0;
            tick();tick();rst=0;tick();
        end
    endtask
    task automatic issue(input [31:0] address);
        integer n;
        begin
            if(returned_token) $fatal(1,"new request before checking completed response");
            va=address;req=1;#1;n=0;
            while(!gnt&&n<40) begin tick();n=n+1;end
            if(!gnt) $fatal(1,"grant timeout for %h",address);
            tick();req=0;va=address+4;
        end
    endtask
    task automatic grant_read(input [31:0] expected,input bit fetch=1);
        integer n;
        begin
            #1;n=0;
            while(!bus_req&&n<40) begin
                if(rvalid) $fatal(1,"expected cache miss at %h, got cached response %h",expected,rdata);
                tick();n=n+1;
            end
            if(!bus_req||bus_addr!==expected||bus_fetch!==fetch)
                $fatal(1,"lower read expected %h got req=%b address=%h fetch=%b",expected,bus_req,bus_addr,bus_fetch);
            bus_gnt=1;tick();bus_gnt=0;
            if(bus_req) $fatal(1,"lower request repeated after grant");
        end
    endtask
    task automatic return_line(input [31:0] value,input bit error=0);
        begin
            bus_line={32'hffeeddcc,32'hbbaa9988,32'h77665544,value};
            if(returned_token) $fatal(1,"lower return overwrote an unchecked response");
            bus_rdata=value;bus_error=error;bus_done=1;#1;
            if(rvalid) begin
                returned_token=1;returned_data=rdata;
                returned_page_fault=page_fault;returned_access_fault=access_fault;
            end
            tick();bus_done=0;bus_error=0;
        end
    endtask
    task automatic response(input [31:0] expected,input bit af=0,input bit advance=1);
        integer n;
        begin
            #1;n=0;
            if(returned_token) begin
                if(returned_data!==expected||returned_page_fault||returned_access_fault!==af)
                    $fatal(1,"completed response data=%h pf=%b af=%b expected=%h af=%b",
                           returned_data,returned_page_fault,returned_access_fault,expected,af);
                returned_token=0;
                if(rvalid) $fatal(1,"completed response was replayed");
                if(advance) tick();
            end else begin
                if(!advance) $fatal(1,"nonadvancing check requires an accepted response");
                while(!rvalid&&n<40) begin
                    if(bus_req) $fatal(1,"expected local response, lower read seen at %h",bus_addr);
                    tick();n=n+1;
                end
                if(!rvalid||rdata!==expected||page_fault||access_fault!==af)
                    $fatal(1,"response valid=%b data=%h pf=%b af=%b expected=%h af=%b",rvalid,rdata,page_fault,access_fault,expected,af);
                tick();
            end
        end
    endtask
    task automatic fill_line(input [31:0] address,input [31:0] value);
        begin issue(address);grant_read(address);return_line(value);response(value);end
    endtask
    task automatic hit(input [31:0] address,input [31:0] expected);
        integer before_bus;
        begin
            before_bus=bus_accepts;issue(address);response(expected);
            if(bus_accepts!=before_bus) $fatal(1,"expected resident line at %h",address);
        end
    endtask
    task automatic cancel_context(input integer kind);
        begin
            case(kind)
                0: fetch_cancel=1;
                1: flush_tlb=1;
                2: satp=32'h00400001;
                3: translate=!translate;
                4: privilege=1;
            endcase
        end
    endtask
    task automatic restore_context;
        begin
            fetch_cancel=0;flush_tlb=0;satp=0;translate=0;privilege=3;
            tick();tick();tick();
        end
    endtask
    // Cancellation drops CPU response/fault tokens. Successful normal RAM
    // completions still warm the physical cache; failed reads never allocate.
    task automatic canceled_return(input integer kind,input integer lead,input bit error);
        integer before_responses;
        begin
            reset_port();before_responses=responses;
            issue(32'h80000100);grant_read(32'h80000100);
            cancel_context(kind);
            if(lead) tick();
            return_line(32'h12345678,error);#1;
            if(rvalid||page_fault||access_fault) $fatal(1,"canceled return exposed response/fault");
            restore_context();
            if(responses!=before_responses) $fatal(1,"canceled return delivered a token");
            if(error) begin
                issue(32'h80000100);grant_read(32'h80000100);
                return_line(32'hc001c0de);response(32'hc001c0de);
            end else hit(32'h80000100,32'h12345678);
            cases=cases+1;
        end
    endtask
    task automatic canceled_done_fault(input integer kind);
        integer before_responses;
        begin
            reset_port();before_responses=responses;
            // Fetch data errors return on completion now. A failed page-table
            // read still owns a registered DONE fault until the following edge.
            translate=1;satp=32'h80080001;privilege=0;tick();tick();
            issue(32'h40000000);grant_read(32'h80001400,0);return_line(0,1);
            #1;if(!rvalid||!access_fault||page_fault||rdata!==32'h13)
                $fatal(1,"page-table error did not produce a precise DONE token");
            cancel_context(kind);#1;
            if(rvalid||page_fault||access_fault) $fatal(1,"late cancellation exposed returned access fault");
            tick();restore_context();
            if(responses!=before_responses) $fatal(1,"late canceled fault delivered a token");
            fill_line(32'h80000100,32'h87654321);
            cases=cases+1;
        end
    endtask
    task automatic snoop_word(input [31:0] address,input [31:0] value,input [3:0] mask,input bit error=0);
        begin
            snoop=1;snoop_addr=address;snoop_data=value;snoop_be=mask;snoop_error=error;
            tick();snoop=0;snoop_error=0;
        end
    endtask

    integer kind,lead,error,n;
    initial begin
        @(negedge clk);
        for(kind=0;kind<5;kind=kind+1)
            for(lead=0;lead<2;lead=lead+1)
                for(error=0;error<2;error=error+1) canceled_return(kind,lead,1'(error));
        for(kind=0;kind<5;kind=kind+1) canceled_done_fault(kind);

        // Fill B followed immediately by a sparse snoop of another resident
        // line A. A single write port must commit both rather than lose A.
        reset_port();fill_line(32'h80000000,32'h33221100);
        issue(32'h80000010);grant_read(32'h80000010);return_line(32'h12345678);
        snoop=1;snoop_addr=32'h80000001;snoop_data=32'h000000a5;snoop_be=1;
        response(32'h12345678);snoop=0;
        hit(32'h80000000,32'h3322a500);hit(32'h80000010,32'h12345678);cases=cases+1;

        // A new byte write overlays the prior full-line fill while that fill
        // commits, then a halfword write follows immediately. Lookup responses
        // must observe both incoming and committing writes without BRAM mode
        // assumptions or losing untouched bytes.
        reset_port();issue(32'h80000000);grant_read(32'h80000000);return_line(32'h33221100);
        snoop=1;snoop_addr=32'h80000001;snoop_data=32'h000000a5;snoop_be=1;
        response(32'h33221100);
        snoop_addr=32'h80000002;snoop_data=32'h0000b6c7;snoop_be=3;
        tick();snoop=0;
        hit(32'h80000000,32'hb6c7a500);cases=cases+1;

        // Keep the hit pipeline active through back-to-back byte/halfword
        // snoops, including a lookup concurrent with the first write.
        reset_port();fill_line(32'h80000000,32'h33221100);
        req=1;va=32'h80000000;snoop=1;snoop_addr=32'h80000001;snoop_data=32'ha5;snoop_be=1;
        #1;if(!gnt) $fatal(1,"initial lookup denied during snoop");
        tick();va=32'h80000000;snoop_addr=32'h80000002;snoop_data=32'hb6c7;snoop_be=3;
        #1;if(!rvalid||rdata!==32'h3322a500||!gnt) $fatal(1,"first colliding lookup lost byte snoop");
        tick();req=0;snoop=0;
        response(32'hb6c7a500);hit(32'h80000000,32'hb6c7a500);cases=cases+1;

        // Same BRAM index, different physical tag: a snoop for the displaced
        // line must never overlay a newly filled instruction line.
        reset_port();fill_line(32'h80000000,32'h33221100);
        issue(32'h80000040);grant_read(32'h80000040);return_line(32'h12345678);
        snoop=1;snoop_addr=32'h80000000;snoop_data=32'hbadbad00;snoop_be=15;
        response(32'h12345678);snoop=0;
        hit(32'h80000040,32'h12345678);
        issue(32'h80000000);grant_read(32'h80000000);return_line(32'hbadbad00);response(32'hbadbad00);cases=cases+1;

        // Error invalidation immediately after a fill must beat its allocation,
        // including forwarding paths that could otherwise resurrect the line.
        reset_port();issue(32'h80000000);grant_read(32'h80000000);return_line(32'h33221100);
        snoop=1;snoop_addr=32'h80000000;snoop_data=0;snoop_be=15;snoop_error=1;
        response(32'h33221100);snoop=0;snoop_error=0;
        tick();issue(32'h80000000);grant_read(32'h80000000);return_line(32'h87654321);response(32'h87654321);cases=cases+1;

        // Independent line updates on consecutive cycles must not alias through
        // the pending-write forwarding slot.
        reset_port();fill_line(32'h80000000,32'h33221100);fill_line(32'h80000010,32'h12345678);
        snoop_word(32'h80000000,32'h000000aa,1);
        snoop_word(32'h80000010,32'h0000bbcc,3);
        hit(32'h80000000,32'h332211aa);hit(32'h80000010,32'h1234bbcc);cases=cases+1;

        // A reset after a returned fill but before its delayed physical write
        // must clear validity and suppress the pending write transaction.
        reset_port();issue(32'h80000000);grant_read(32'h80000000);return_line(32'h33221100);
        response(32'h33221100,0,0);
        reset_port();fill_line(32'h80000000,32'h87654321);cases=cases+1;

        if(returned_token) $fatal(1,"unchecked completed response at test end");
        $display("PASS: frontend cache transactions %0d cases; cancel/flush/context return and fault races; ordered fill/snoops; collision forwarding/tags/error/reset",cases);
        $finish;
    end
    initial begin #1000000;$fatal(1,"global timeout");end
endmodule
