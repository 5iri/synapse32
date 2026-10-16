`timescale 1ns/1ps
`default_nettype none
module tb_fetch_access_fault #(parameter ERROR_CASE=0);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    wire [27:0] axi_addr;
    wire arvalid,rready,awvalid,wvalid,bready;
    reg rvalid=0,bvalid=0;
    reg [127:0] rdata=0;
    reg [1:0] rresp=0;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire uart_tx,boot_done,fault,core_enable;
    wire [31:0] pc_debug;
    reg have_aw=0,have_w=0;
    wire arready=!rvalid&&(read_delay==0),awready=!have_aw&&!bvalid,wready=!have_w&&!bvalid;
    reg [27:0] read_addr,write_addr;
    reg [127:0] write_data;
    reg [15:0] write_strobes;
    reg [127:0] ram[0:1023];
    reg error_read=0;
    integer read_delay=0,write_delay=0,n,lane;
    integer error_responses=0,cancel_inflight=0,discarded_errors=0,fault_cycles=0;
    localparam BOOT_FILE=ERROR_CASE==0 ? "build/fetch-fault-0.hex" :
                         ERROR_CASE==1 ? "build/fetch-fault-1.hex" : "build/fetch-fault-2.hex";
    synapse_ddr3_system #(.BOOT_WORDS(512),.BOOT_FILE(BOOT_FILE),.FETCH_QUEUE(1),
        .ITERATIVE_MULDIV(1),.FAST_L1(1),.DCACHE_LINES(256),.ICACHE_LINES(256),
        .STORE_BUFFER_DEPTH(0),.FAST_MULTIPLY(0)) dut (
        .clk(clk),.rst(rst),.calibrated(1'b1),.uart_rx(1'b1),.uart_tx(uart_tx),
        .boot_done(boot_done),.fault(fault),.core_enable(core_enable),.pc_debug(pc_debug),
        .load_req(1'b0),.load_finish(1'b0),.load_addr(32'b0),.load_data(32'b0),.load_ready(),.load_done(),
        .axi_addr(axi_addr),.arvalid(arvalid),.arready(arready),.rvalid(rvalid),.rready(rready),
        .rlast(1'b1),.rdata(rdata),.rresp(rresp),.awvalid(awvalid),.awready(awready),
        .wvalid(wvalid),.wready(wready),.wdata(wdata),.wstrb(wstrb),.bvalid(bvalid),.bready(bready),.bresp(2'b0)
    );
    function automatic [9:0] ram_index(input [27:0] address);
        reg [27:0] mapped;
        begin
            mapped=address>=28'h4000000 ? address-28'h4000000+28'h2000 : address;
            if(mapped>=28'h4000) $fatal(1,"RAM address out of test range %h",address);
            ram_index=10'(mapped>>4);
        end
    endfunction
    wire inject=boot_done&&((ERROR_CASE==0&&axi_addr==28'h400)||
                           (ERROR_CASE==1&&axi_addr==28'h140)||
                           (ERROR_CASE==2&&axi_addr==28'h4000080));
    always @(posedge clk) begin
        if(!rst) begin
            if(arvalid&&arready) begin
                read_addr<=axi_addr;error_read<=inject;rresp<=inject ? 2 : 0;
                read_delay<=(ERROR_CASE==1&&inject) ? 100 : 4;
            end else if(read_delay>1) read_delay<=read_delay-1;
            else if(read_delay==1) begin rdata<=ram[ram_index(read_addr)];rvalid<=1;read_delay<=0;end
            if(rvalid&&rready) begin
                rvalid<=0;
                if(error_read) begin
                    error_responses<=error_responses+1;
                    if(dut.instr_port.walk_discard) discarded_errors<=discarded_errors+1;
                end
            end
            if(ERROR_CASE==1&&error_read&&(read_delay>0||rvalid)&&dut.fetch_cancel)
                cancel_inflight<=cancel_inflight+1;
            if(awvalid&&awready) begin write_addr<=axi_addr;have_aw<=1;end
            if(wvalid&&wready) begin write_data<=wdata;write_strobes<=wstrb;have_w<=1;end
            if(have_aw&&have_w&&write_delay==0&&!bvalid) write_delay<=4;
            else if(write_delay>1) write_delay<=write_delay-1;
            else if(write_delay==1) begin
                for(lane=0;lane<16;lane=lane+1)
                    if(write_strobes[lane]) ram[ram_index(write_addr)][lane*8+:8]<=write_data[lane*8+:8];
                bvalid<=1;write_delay<=0;
            end
            if(bvalid&&bready) begin bvalid<=0;have_aw<=0;have_w<=0;end
            if(fault) begin
                if(ERROR_CASE!=2) $fatal(1,"instruction response caused a global fabric fault");
                if(core_enable) $fatal(1,"CPU enabled after fatal data response");
                fault_cycles<=fault_cycles+1;
                if(fault_cycles==8) begin
                    if(error_responses==0) $fatal(1,"data error coverage absent");
                    $display("PASS fetch access-fault case2: data read error retains fatal behavior");$finish;
                end
            end
            if(core_enable&&ram[512][127:96]==32'hdead)
                $fatal(1,"unexpected trap/result case%0d cause=%h epc=%h tval=%h",ERROR_CASE,ram[512][31:0],ram[512][63:32],ram[512][95:64]);
            if(core_enable&&ram[512][127:96]==32'h600d) begin
                if(error_responses==0) $fatal(1,"no injected error returned");
                if(ERROR_CASE==0) begin
                    if(ram[512][31:0]!=1||ram[512][63:32]!=32'h80000400||ram[512][95:64]!=32'h80000400)
                        $fatal(1,"instruction access fault metadata mismatch");
                    $display("PASS fetch access-fault case0: handled cause1 atPC80000400 without fabric halt");
                end else if(ERROR_CASE==1) begin
                    if(cancel_inflight==0||discarded_errors==0||ram[512][31:0]!=3)
                        $fatal(1,"wrong-path cancellation coverage absent cancel=%0d discard=%0d",cancel_inflight,discarded_errors);
                    $display("PASS fetch access-fault case1: canceled in-flight wrong-path bus error drained without trap/halt");
                end else $fatal(1,"data error failed to halt");
                $finish;
            end
        end
    end
    initial begin
        for(n=0;n<1024;n=n+1) ram[n]=0;
        repeat(5) @(negedge clk);rst=0;
        repeat(30000) @(negedge clk);
        $fatal(1,"timeout case%0d PC=%h responses=%0d cancels=%0d",ERROR_CASE,pc_debug,error_responses,cancel_inflight);
    end
endmodule
