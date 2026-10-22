`timescale 1ns/1ps
`default_nettype none
// Successful speculative RAM reads may populate the physically tagged cache;
// request ownership, faults, translation permissions and snoop ordering remain precise.
module tb_speculative_fetch_fill;
    reg clk=0,rst=1; always #5 clk=~clk;
    reg req=0,cancel=0,flush=0,translate=0;
    reg [31:0] va=32'h80000000,satp=0; reg [1:0] privilege=3;
    wire gnt,rvalid,page_fault,access_fault,fatal_error,bus_req,bus_we,bus_fetch;
    wire [31:0] rdata,bus_addr,bus_wdata;wire [3:0] bus_be;
    reg bus_gnt=0,bus_done=0,bus_error=0;
    reg [31:0] bus_rdata=0;reg [127:0] bus_line=0;
    reg snoop=0,snoop_error=0;reg [31:0] snoop_addr=0,snoop_data=0;reg [3:0] snoop_be=0;
    integer responses=0,grants=0,lower_grants=0,cases=0;
    localparam [31:0] A=32'h80000000,V=32'h40000000;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(4),.PIPELINED_FETCH(1),.RESTART_ON_CANCEL(1)) dut (
      .clk(clk),.rst(rst),.flush_tlb(flush),.fetch_cancel(cancel),.req(req),.we(1'b0),.write_intent(1'b0),
      .translate(translate),.va(va),.satp(satp),.wdata(32'b0),.privilege(privilege),.sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'd2),
      .gnt(gnt),.rvalid(rvalid),.page_fault(page_fault),.access_fault(access_fault),.rdata(rdata),
      .bus_req(bus_req),.bus_we(bus_we),.bus_fetch(bus_fetch),.bus_addr(bus_addr),.bus_wdata(bus_wdata),.bus_be(bus_be),
      .bus_gnt(bus_gnt),.bus_done(bus_done),.bus_rdata(bus_rdata),.bus_line(bus_line),.bus_error(bus_error),
      .snoop(snoop),.snoop_addr(snoop_addr),.snoop_data(snoop_data),.snoop_be(snoop_be),.snoop_error(snoop_error),
      .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),.fatal_error(fatal_error));
    always @(posedge clk) if(!rst) begin
      if(rvalid)responses=responses+1;if(gnt)grants=grants+1;if(bus_req&&bus_gnt)lower_grants=lower_grants+1;
      if(fatal_error||bus_we) $fatal(1,"speculative fetch raised fatal error or write");
      if(cancel&&rvalid) $fatal(1,"canceled fetch exposed a response");
      if(page_fault&&access_fault) $fatal(1,"overlapping fault classes");
    end
    function automatic [31:0] word_at(input [31:0] addr);word_at=32'hb16b00b5^addr;endfunction
    task automatic tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    task automatic reset_port;begin
      rst=1;req=0;cancel=0;flush=0;translate=0;satp=0;privilege=3;bus_gnt=0;bus_done=0;bus_error=0;snoop=0;snoop_error=0;
      tick();tick();rst=0;tick();responses=0;grants=0;lower_grants=0;
    end endtask
    task automatic issue(input [31:0] address);integer n;begin
      va=address;req=1;#1;n=0;while(!gnt&&n<40)begin tick();n=n+1;end
      if(!gnt)$fatal(1,"request grant timeout %h",address);tick();req=0;
    end endtask
    task automatic grant_lower(input [31:0] expected,input bit instruction=1);integer n;begin
      #1;n=0;while(!bus_req&&n<40)begin
        if(rvalid)$fatal(1,"expected lower read, got response %h",rdata);tick();n=n+1;
      end
      if(!bus_req||bus_addr!==expected||bus_fetch!==instruction)$fatal(1,"lower request mismatch got %h fetch=%b expected %h fetch=%b",bus_addr,bus_fetch,expected,instruction);
      bus_gnt=1;tick();bus_gnt=0;
    end endtask
    task automatic set_completion(input [31:0] addr,input bit error=0);integer n;begin
      for(n=0;n<4;n=n+1)bus_line[n*32+:32]=word_at((addr&32'hfffffff0)+32'(n*4));
      bus_rdata=word_at(addr);bus_error=error;bus_done=1;#1;
    end endtask
    task automatic finish_completion;begin tick();bus_done=0;bus_error=0;end endtask
    task automatic expect_response(input [31:0] expected,input bit pf=0,input bit af=0);integer n;begin
      #1;n=0;while(!rvalid&&n<40)begin
        if(bus_req)$fatal(1,"retained speculative line unexpectedly requested lower bus at %h",bus_addr);
        tick();n=n+1;
      end
      if(!rvalid||rdata!==expected||page_fault!==pf||access_fault!==af)$fatal(1,"response mismatch valid=%b data=%h pf=%b af=%b expected=%h pf=%b af=%b",rvalid,rdata,page_fault,access_fault,expected,pf,af);
      tick();
    end endtask
    task automatic quiet(input integer rsp,input integer accepted,input integer lower);begin
      req=0;repeat(3)begin #1;if(rvalid||page_fault||access_fault)$fatal(1,"duplicate or canceled token");tick();end
      if(responses!=rsp||grants!=accepted||lower_grants!=lower)$fatal(1,"token counts responses=%0d grants=%0d lower=%0d expected %0d/%0d/%0d",responses,grants,lower_grants,rsp,accepted,lower);
      cases=cases+1;
    end endtask
    task automatic context_event(input integer kind);begin
      case(kind)
        0:cancel=1;1:flush=1;2:satp=32'h80080001;3:privilege=1;4:translate=1;
      endcase
    end endtask
    task automatic restore_context;begin
      cancel=0;flush=0;translate=0;satp=0;privilege=3;tick();tick();
    end endtask
    task automatic canceled_read(input integer kind,input integer lead,input bit error);begin
      issue(A);grant_lower(A);context_event(kind);
      if(lead)begin tick();cancel=0;flush=0;repeat(2)tick();end
      set_completion(A,error);
      if(rvalid||page_fault||access_fault)$fatal(1,"canceled completion escaped kind=%0d lead=%0d error=%b",kind,lead,error);
      finish_completion();restore_context();
      if(responses!=0)$fatal(1,"canceled operation produced a token");
    end endtask
    task automatic retry_success(input [31:0] address);begin
      issue(address);grant_lower(address);set_completion(address);expect_response(word_at(address));bus_done=0;
    end endtask
    task automatic pte_response(input [31:0] value);begin
      bus_done=1;bus_error=0;bus_rdata=value;tick();bus_done=0;
    end endtask
    task automatic snoop_once(input [31:0] address,input [31:0] value,input [3:0] mask,input bit error=0);begin
      snoop=1;snoop_addr=address;snoop_data=value;snoop_be=mask;snoop_error=error;tick();snoop=0;snoop_error=0;
    end endtask
    // Leave the successful abandoned fill in its registered pending state.
    task automatic pending_canceled_fill;begin
      issue(A);grant_lower(A);cancel=1;tick();cancel=0;set_completion(A);
      if(rvalid||page_fault||access_fault)$fatal(1,"pending canceled fill leaked a token");finish_completion();
    end endtask
    integer kind,lead,n,width;
    reg [31:0] expected,store_value,store_address;
    reg [3:0] mask;
    initial begin
      @(negedge clk);
      // Exact public token counts prove that retaining bytes never revives the
      // abandoned transaction. Every word in the returned line is checked.
      for(kind=0;kind<5;kind=kind+1)for(lead=0;lead<2;lead=lead+1)begin
        reset_port();canceled_read(kind,lead,0);
        for(n=0;n<4;n=n+1)begin issue(A+32'(4*n));expect_response(word_at(A+32'(4*n)));end
        quiet(4,5,1);
      end
      $display("CASE retained_bytes cancel/flush/satp/privilege/translation completion/before PASS");
      // Failed speculative reads never allocate and never expose a fault token.
      for(kind=0;kind<5;kind=kind+1)for(lead=0;lead<2;lead=lead+1)begin
        reset_port();canceled_read(kind,lead,1);retry_success(A);quiet(1,2,2);
      end
      $display("CASE canceled_errors never_fill PASS");
      // A new same-line target may take ownership on the completion edge; its
      // hit must use retained bytes while the old response remains suppressed.
      reset_port();issue(A);grant_lower(A);cancel=1;req=1;va=A+4;set_completion(A);
      if(!gnt||rvalid||page_fault||access_fault)$fatal(1,"completion-edge restart lost ownership");
      finish_completion();cancel=0;req=0;expect_response(word_at(A+4));quiet(1,2,1);
      reset_port();issue(A);grant_lower(A);cancel=1;req=1;va=A+4;set_completion(A,1);
      if(!gnt||rvalid||page_fault||access_fault)$fatal(1,"error completion restart ownership");
      finish_completion();cancel=0;req=0;grant_lower(A+4);set_completion(A+4);expect_response(word_at(A+4));bus_done=0;quiet(1,2,2);
      $display("CASE completion_restart success/error exact_tokens PASS");
      // A retained physical line is accessible through a fresh authorized walk.
      // The same resident bytes cannot bypass privilege or new-root permissions.
      reset_port();canceled_read(0,1,0);translate=1;satp=32'h80080001;privilege=0;tick();tick();
      issue(V);grant_lower(32'h80001400,0);pte_response(32'h20000801);
      grant_lower(32'h80002000,0);pte_response(32'h2000005b);expect_response(word_at(A));
      privilege=1;tick();tick();issue(V);expect_response(32'h13,1,0);
      quiet(2,3,3);
      privilege=0;satp=32'h80080003;tick();tick();
      issue(V);grant_lower(32'h80003400,0);pte_response(32'h20000801);
      grant_lower(32'h80002000,0);pte_response(32'h20000053);expect_response(32'h13,1,0);
      quiet(3,4,5);
      satp=32'h80080004;tick();tick();issue(V);
      grant_lower(32'h80004400,0);pte_response(32'h20000801);
      grant_lower(32'h80002000,0);pte_response(32'h2000004b);expect_response(32'h13,1,0);
      quiet(4,5,7);
      restore_context();issue(A);expect_response(word_at(A));quiet(5,6,7);
      $display("CASE resident_bytes require fresh satp/execute/user permissions PASS");
      // Each snoop immediately follows the fill-capture edge. This exercises
      // pending metadata and old-fill/new-store byte forwarding, then the data
      // is read back while the snoop itself commits to BRAM.
      for(width=0;width<3;width=width+1)begin
        reset_port();pending_canceled_fill();expected=word_at(A);store_value=32'ha1b2c3d4;
        case(width)
          0:begin store_address=A+1;mask=1;expected[15:8]=store_value[7:0];end
          1:begin store_address=A+2;mask=3;expected[31:16]=store_value[15:0];end
          2:begin store_address=A;mask=15;expected=store_value;end
        endcase
        snoop_once(store_address,store_value,mask);issue(A);expect_response(expected);
        issue(A+4);expect_response(word_at(A+4));quiet(2,3,1);
      end
      // Three consecutive write events must each survive the single BRAM port.
      reset_port();pending_canceled_fill();snoop_once(A+1,32'ha5,1);
      snoop_once(A+2,32'hbeef,3);snoop_once(A+4,32'hcafef00d,15);
      issue(A);expect_response(32'hbeefa5b5);issue(A+4);expect_response(32'hcafef00d);quiet(2,3,1);
      // A same-index, different physical tag must not modify retained bytes.
      reset_port();pending_canceled_fill();snoop_once(A+64,32'hdeadbeef,15);
      issue(A);expect_response(word_at(A));quiet(1,2,1);
      // A failed byte write invalidates the pending physical line. It cannot
      // create a hit from partial or stale bytes, and the retry reads memory.
      reset_port();pending_canceled_fill();snoop_once(A+1,32'h55,1,1);repeat(2)tick();
      retry_success(A);quiet(1,2,2);
      $display("CASE next_cycle byte/half/word/consecutive/alias/error snoops PASS");
      // Reset on the pending-fill commit edge clears validity and suppresses
      // its registered write event; no pre-reset data/token may reappear.
      reset_port();pending_canceled_fill();reset_port();retry_success(A);quiet(1,1,1);
      $display("CASE reset clears pending metadata PASS");
      $display("SPECULATIVE_FETCH_FILL cases=%0d PASS",cases);$finish;
    end
endmodule
