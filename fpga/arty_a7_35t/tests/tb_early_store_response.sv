`timescale 1ns/1ps
`default_nettype none
// Isolate the data-port response protocol; the integrated posted-store test
// separately checks FENCE/FENCE.I and LR/SC/AMO ordering against physical AXI.
module tb_early_store_response #(parameter EARLY=1);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg req=0,we=0,translate=0,flush_tlb=0;
    reg [31:0] va=0,wdata=0,satp=0;
    reg [3:0] be=15;
    reg [1:0] privilege=3;
    wire gnt,rvalid,page_fault,access_fault,fatal_error,bus_req,bus_we,bus_fetch;
    wire [31:0] rdata,bus_addr,bus_wdata;
    wire [3:0] bus_be;
    reg bus_gnt=0,bus_done=0,bus_error=0;
    reg [31:0] bus_rdata=0;
    wire [127:0] bus_line={4{bus_rdata}};
    sv32_bus_port #(.FETCH(0),.CACHE_LINES(0),.EARLY_STORE_RESPONSE(EARLY)) dut (
        .clk(clk),.rst(rst),.flush_tlb(flush_tlb),.fetch_cancel(1'b0),
        .req(req),.we(we),.write_intent(we),.translate(translate),
        .va(va),.satp(satp),.wdata(wdata),.privilege(privilege),
        .sum(1'b0),.mxr(1'b0),.be(be),.load_type(3'd2),
        .gnt(gnt),.rvalid(rvalid),.page_fault(page_fault),.access_fault(access_fault),.rdata(rdata),
        .bus_req(bus_req),.bus_we(bus_we),.bus_fetch(bus_fetch),.bus_addr(bus_addr),
        .bus_wdata(bus_wdata),.bus_be(bus_be),.bus_gnt(bus_gnt),.bus_done(bus_done),
        .bus_rdata(bus_rdata),.bus_line(bus_line),.bus_error(bus_error),
        .snoop(1'b0),.snoop_addr(32'b0),.snoop_data(32'b0),.snoop_be(4'b0),.snoop_error(1'b0),
        .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),.fatal_error(fatal_error)
    );
    reg [7:0] ram[0:63];
    reg active=0,held_we=0;
    reg [31:0] held_addr=0,held_data=0;
    reg [3:0] held_be=0;
    integer responses=0,grants=0,commits=0,lane,offset,n;
    always @(posedge clk) begin
        if(rst) active=0;
        else begin
            if(rvalid) responses=responses+1;
            if(bus_req&&bus_gnt) begin
                if(active) $fatal(1,"second lower grant before completion");
                held_we=bus_we;held_addr=bus_addr;held_data=bus_wdata;held_be=bus_be;
                active=1;grants=grants+1;
            end
            if(bus_done) begin
                if(!active) $fatal(1,"response without a lower grant");
                if(held_we&&!bus_error) begin
                    commits=commits+1;
                    if(held_addr>=32'h80000000&&held_addr<32'h8000003c) begin
                        offset=int'(held_addr-32'h80000000);
                        for(lane=0;lane<4;lane=lane+1)
                            if(held_be[lane]) ram[offset+lane]=held_data[8*lane+:8];
                    end
                end
                active=0;
            end
            if(rvalid&&access_fault) $fatal(1,"data port exposed fetch access fault");
        end
    end
    task automatic tick;
        begin @(posedge clk);#1;@(negedge clk);end
    endtask
    task automatic reset_port;
        begin
            req=0;bus_gnt=0;bus_done=0;bus_error=0;translate=0;satp=0;privilege=3;rst=1;
            tick();tick();rst=0;tick();tick();
            if(rvalid||fatal_error||bus_req) $fatal(1,"reset did not clear port");
        end
    endtask
    task automatic drive(input bit wr,input [31:0] address,input [31:0] value,input [3:0] strobes=15);
        begin req=1;we=wr;va=address;wdata=value;be=strobes;#1;end
    endtask
    task automatic release_inputs;
        begin req=0;we=!we;va=32'hbad0bad0;wdata=32'hbad1bad1;be=0;#1;end
    endtask
    task automatic issue(input bit wr,input [31:0] address,input [31:0] value,input [3:0] strobes=15);
        integer waited;
        begin
            drive(wr,address,value,strobes);waited=0;
            while(!gnt&&waited<40) begin tick();waited=waited+1;end
            if(!gnt) $fatal(1,"CPU request not granted");
            tick();release_inputs();
        end
    endtask
    task automatic grant_lower(input bit wr,input [31:0] address,input [31:0] value=0,input [3:0] strobes=15);
        integer waited;
        begin
            waited=0;#1;
            while(!bus_req&&waited<40) begin tick();waited=waited+1;end
            if(!bus_req||bus_we!==wr||bus_addr!==address) $fatal(1,"lower request metadata mismatch");
            if(wr&&(bus_wdata!==value||bus_be!==strobes)) $fatal(1,"store snapshot lost");
            if(rvalid) $fatal(1,"response before lower grant");
            bus_gnt=1;#1;if(rvalid) $fatal(1,"store acknowledged on grant");
            tick();bus_gnt=0;#1;
            if(bus_req||rvalid) $fatal(1,"grant was confused with completion");
        end
    endtask
    task automatic complete_lower(input [31:0] value=0,input bit failed=0);
        integer before_count;
        bit was_write;
        begin
            before_count=responses;was_write=held_we;
            bus_rdata=value;bus_error=failed;bus_done=1;#1;
            if(rvalid!==(EARLY&&was_write&&!failed))
                $fatal(1,"completion-edge rvalid mismatch early=%0d write=%b error=%b",EARLY,was_write,failed);
            tick();bus_done=0;bus_error=0;#1;
            if(failed) begin
                if(rvalid||responses!=before_count||!fatal_error) $fatal(1,"error acknowledged as success");
            end else if(EARLY&&was_write) begin
                if(rvalid||responses!=before_count+1||dut.state!=3'd0) $fatal(1,"early write entered DONE or duplicated ack");
            end else begin
                if(!rvalid||page_fault||fatal_error) $fatal(1,"legacy completion response missing");
                if(!was_write&&rdata!==value) $fatal(1,"load response corrupted");
                tick();#1;
                if(rvalid||responses!=before_count+1) $fatal(1,"legacy response repeated");
            end
        end
    endtask
    task automatic complete_pte(input [31:0] value);
        begin
            bus_rdata=value;bus_done=1;#1;
            if(rvalid) $fatal(1,"PTE read acknowledged as CPU access");
            tick();bus_done=0;#1;
            if(rvalid) $fatal(1,"nonfaulting PTE read produced CPU response");
        end
    endtask
    task automatic idle_check;
        integer before_count;
        begin
            before_count=responses;tick();tick();
            if(rvalid||bus_req||responses!=before_count) $fatal(1,"duplicate trailing response/request");
        end
    endtask
    integer before_responses,before_grants,before_commits,which;
    reg [31:0] expected;
    initial begin
        for(n=0;n<64;n=n+1) ram[n]=0;
        @(negedge clk);reset_port();
        // Posted-like response one cycle after lower grant; a byte write must
        // preserve the captured unaligned address/data/strobes.
        issue(1,32'h80000003,32'ha5,1);grant_lower(1,32'h80000003,32'ha5,1);complete_lower();idle_check();
        if(ram[3]!==8'ha5) $fatal(1,"byte store did not commit");
        // Backpressure before grant and a long delayed completion cannot ack.
        issue(1,32'h80000004,32'h44332211,5);
        repeat(4) begin #1;if(rvalid||!bus_req||bus_addr!==32'h80000004) $fatal(1,"grant backpressure violated");tick();end
        grant_lower(1,32'h80000004,32'h44332211,5);
        repeat(5) begin if(rvalid) $fatal(1,"response backpressure violated");tick();end
        complete_lower();idle_check();
        expected={ram[7],ram[6],ram[5],ram[4]};
        issue(0,32'h80000004,0);grant_lower(0,32'h80000004);complete_lower(expected);idle_check();

        // Queue another CPU request while a write waits, then accept it only
        // after the old response. Exercise write->write->read without reset.
        before_responses=responses;
        issue(1,32'h80000008,32'h11223344);grant_lower(1,32'h80000008,32'h11223344);
        drive(1,32'h8000000c,32'h55667788);if(gnt) $fatal(1,"new write accepted before prior completion");
        complete_lower();#1;if(!gnt) $fatal(1,"port did not reopen after write response");
        tick();release_inputs();grant_lower(1,32'h8000000c,32'h55667788);
        drive(0,32'h80000008,0);if(gnt) $fatal(1,"read accepted before prior write completion");
        complete_lower();#1;if(!gnt) $fatal(1,"read did not follow write");
        tick();release_inputs();grant_lower(0,32'h80000008);complete_lower(32'h11223344);idle_check();
        if(responses!=before_responses+3) $fatal(1,"successive request response count");

        // MMIO is nonposted here: grant alone may not acknowledge its write.
        issue(1,32'h20000000,32'h41,1);grant_lower(1,32'h20000000,32'h41,1);
        repeat(6) begin if(rvalid) $fatal(1,"MMIO acknowledged before completion");tick();end
        complete_lower();idle_check();

        // Readable user leaf: stores must still check W and D on the TLB hit.
        for(which=0;which<2;which=which+1) begin
            translate=1;satp=32'h80080001;privilege=0;flush_tlb=1;tick();flush_tlb=0;tick();
            issue(0,32'h40000000,0);
            grant_lower(0,32'h80001400);complete_pte(32'h20000801);
            grant_lower(0,32'h80002000);complete_pte(which==0 ? 32'h20000053 : 32'h20000057);
            grant_lower(0,32'h80000000);complete_lower(32'ha5000000);
            before_grants=grants;before_commits=commits;
            issue(1,32'h40000000,32'hdeadbeef);
            if(!rvalid||!page_fault||bus_req) $fatal(1,"write permission fault bypassed");
            tick();idle_check();
            if(grants!=before_grants||commits!=before_commits) $fatal(1,"permission-faulted store reached RAM");
        end

        // Neither a failed store nor a failed load can produce a success ack.
        reset_port();issue(1,32'h80000010,32'hdeadbeef);grant_lower(1,32'h80000010,32'hdeadbeef);
        before_commits=commits;complete_lower(0,1);
        if(commits!=before_commits) $fatal(1,"failed store committed");
        reset_port();issue(0,32'h80000010,0);grant_lower(0,32'h80000010);complete_lower(0,1);
        $display("PASS: early store response mode=%0d responses=%0d grants=%0d commits=%0d",EARLY,responses,grants,commits);
        $finish;
    end
    initial begin #1000000;$fatal(1,"global timeout");end
endmodule
