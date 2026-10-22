`timescale 1ns/1ps
`default_nettype none
module tb_fetch_completion;
    reg clk=0,rst=1; always #5 clk=~clk;
    reg req=0,cancel=0,flush=0,translate=0;
    reg [31:0] va=32'h80000000,satp=0;
    reg [1:0] privilege=3;
    wire gnt,rvalid,page_fault,access_fault,fatal_error,bus_req,bus_we,bus_fetch;
    wire [31:0] rdata,bus_addr,bus_wdata; wire [3:0] bus_be;
    reg bus_gnt=0,bus_done=0,bus_error=0;
    reg [31:0] bus_rdata=0; reg [127:0] bus_line=0;
    integer responses=0,grants=0,lower_grants=0,cases=0,cycle=0;
    localparam [31:0] A=32'h80000000,B=32'h80000040;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(16),.PIPELINED_FETCH(1),.RESTART_ON_CANCEL(1)) dut (
      .clk(clk),.rst(rst),.flush_tlb(flush),.fetch_cancel(cancel),.req(req),.we(1'b0),.write_intent(1'b0),.translate(translate),
      .va(va),.satp(satp),.wdata(32'b0),.privilege(privilege),.sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'd2),
      .gnt(gnt),.rvalid(rvalid),.page_fault(page_fault),.access_fault(access_fault),.rdata(rdata),
      .bus_req(bus_req),.bus_we(bus_we),.bus_fetch(bus_fetch),.bus_addr(bus_addr),.bus_wdata(bus_wdata),.bus_be(bus_be),
      .bus_gnt(bus_gnt),.bus_done(bus_done),.bus_rdata(bus_rdata),.bus_line(bus_line),.bus_error(bus_error),
      .snoop(1'b0),.snoop_addr(32'b0),.snoop_data(32'b0),.snoop_be(4'b0),.snoop_error(1'b0),
      .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),.fatal_error(fatal_error));
    always @(posedge clk) begin
      cycle=cycle+1;
      if(!rst) begin
        if(rvalid) responses=responses+1;
        if(gnt) grants=grants+1;
        if(bus_req&&bus_gnt) lower_grants=lower_grants+1;
        if(fatal_error||bus_we||page_fault) $fatal(1,"unexpected fatal/write/pagefault");
        if(cancel&&rvalid) $fatal(1,"canceled response visible");
      end
    end
    function automatic [31:0] word_at(input [31:0] addr);word_at=32'hc0de0000^addr;endfunction
    task automatic tick; begin @(posedge clk);#1;@(negedge clk);end endtask
    task automatic reset_port; begin
      rst=1;req=0;cancel=0;flush=0;bus_gnt=0;bus_done=0;bus_error=0;translate=0;satp=0;privilege=3;
      tick();tick();rst=0;tick();responses=0;grants=0;lower_grants=0;
    end endtask
    task automatic issue(input [31:0] addr);integer n;begin
      req=1;va=addr;#1;n=0;
      while(!gnt&&n<30) begin tick();n=n+1;end
      if(!gnt) $fatal(1,"issue grant timeout %h",addr);
      tick();req=0;
    end endtask
    task automatic grant_lower(input [31:0] addr);integer n;begin
      #1;n=0;while(!bus_req&&n<30)begin tick();n=n+1;end
      if(!bus_req||bus_addr!==addr) $fatal(1,"lower req got %b %h expected %h",bus_req,bus_addr,addr);
      bus_gnt=1;tick();bus_gnt=0;
    end endtask
    task automatic set_done(input [31:0] addr,input bit error=0);integer n;begin
      for(n=0;n<4;n=n+1)bus_line[n*32+:32]=word_at((addr&32'hfffffff0)+32'(n*4));
      bus_rdata=word_at(addr);bus_error=error;bus_done=1;#1;
    end endtask
    task automatic expect_response(input [31:0] addr,input bit error=0);begin
      #1;if(!rvalid||rdata!==(error ? 32'h13 : word_at(addr))||access_fault!==error)
        $fatal(1,"completion response got valid=%b word=%h af=%b expected %h af=%b",rvalid,rdata,access_fault,(error ? 32'h13 : word_at(addr)),error);
    end endtask
    task automatic finish_done;begin tick();bus_done=0;bus_error=0;#1;end endtask
    task automatic quiet(input integer expected_rsp,input integer expected_grants,input integer expected_lower);begin
      req=0;repeat(3)begin if(rvalid) $fatal(1,"duplicate response");tick();end
      if(responses!=expected_rsp||grants!=expected_grants) $fatal(1,"ownership count responses=%0d grants=%0d expected %0d %0d",responses,grants,expected_rsp,expected_grants);
      if(lower_grants!=expected_lower) $fatal(1,"lower grants=%0d expected %0d",lower_grants,expected_lower);
      cases=cases+1;
    end endtask
    initial begin
      // Completion response and same-line next grant share one edge. The next
      // cache hit is valid on the following edge, using the in-progress fill.
      reset_port();issue(A);grant_lower(A);repeat(3)tick();
      req=1;va=A+4;set_done(A);expect_response(A);
      if(!gnt) $fatal(1,"next same-line lookup lost completion-edge grant");
      finish_done();req=0;expect_response(A+4);tick();quiet(2,2,1);
      $display("CASE same_line response_gap=1 completion_grant_gap=0 PASS");
      // Next-line lookup may miss; no accidental hit or reuse of the old line.
      reset_port();issue(A);grant_lower(A);req=1;va=A+16;set_done(A);expect_response(A);
      if(!gnt) $fatal(1,"next-line completion-edge grant absent");
      finish_done();req=0;#1;if(rvalid) $fatal(1,"new line incorrectly hit old fill");
      grant_lower(A+16);set_done(A+16);expect_response(A+16);finish_done();quiet(2,2,2);
      // Error travels with its completed fetch and never fills the cache.
      reset_port();issue(A);grant_lower(A);req=1;va=A+4;set_done(A,1);expect_response(A,1);
      if(gnt) $fatal(1,"failed completion accepted a following request");
      finish_done();req=0;issue(A+4);#1;if(rvalid) $fatal(1,"failed fill became a hit");
      grant_lower(A+4);set_done(A+4);expect_response(A+4);finish_done();quiet(2,2,2);
      // A previously granted lower read drains despite an earlier cancel. The
      // replacement request must not be accepted before the old read completes.
      reset_port();issue(A);grant_lower(A);cancel=1;req=1;va=B;#1;
      if(gnt||rvalid) $fatal(1,"granted lower read ownership lost before drain");
      tick();cancel=0;repeat(4)begin #1;if(gnt||rvalid) $fatal(1,"discarded transaction responded before drain");tick();end
      set_done(A);if(gnt||rvalid) $fatal(1,"old drain escaped token");finish_done();
      #1;if(!gnt) $fatal(1,"replacement not accepted after drain");tick();req=0;
      grant_lower(B);set_done(B);expect_response(B);finish_done();quiet(1,2,2);
      // Cancellation exactly on completion can atomically replace ownership.
      // The old response disappears; its successful physical refill supplies
      // the replacement request, without a second lower transaction.
      reset_port();issue(A);grant_lower(A);cancel=1;req=1;va=A+4;set_done(A);
      if(!gnt||rvalid) $fatal(1,"completion cancel replacement broken");
      finish_done();cancel=0;req=0;expect_response(A+4);tick();quiet(1,2,1);
      // No next request: completion is a single response, with no DONE replay.
      reset_port();issue(A);grant_lower(A);set_done(A);expect_response(A);finish_done();quiet(1,1,1);
      $display("FETCH_COMPLETION cases=%0d PASS",cases);$finish;
    end
endmodule
