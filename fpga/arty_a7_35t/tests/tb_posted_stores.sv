`timescale 1ns/1ps
`default_nettype none
`include "instr_defines.vh"
// Integrated core/translation/L1/posted queue with deliberately slow AXI writes.
module tb_posted_stores #(parameter DEPTH=4, FAST_MULTIPLY=0);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    wire [27:0] axi_addr;
    wire arvalid,rready,awvalid,wvalid,bready;
    reg rvalid=0,bvalid=0;
    reg [127:0] rdata=0;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire uart_tx,boot_done,fault,core_enable;
    wire [31:0] pc_debug;
    reg have_aw=0,have_w=0;
    wire arready=!rvalid&&(read_delay==0);
    wire awready=!have_aw&&!bvalid;
    wire wready=!have_w&&!bvalid;
    reg [27:0] read_addr,write_addr;
    reg [127:0] write_data;
    reg [15:0] write_strobes;
    reg [127:0] ram[0:8191];
    integer read_delay=0,write_delay=0,n,lane,cycles=0;
    integer posted=0,pending_hits=0,pending_misses=0,fence_waits=0,fence_i_waits=0;
    integer lr_waits=0,sc_waits=0,amo_waits=0,failed_sc_waits=0,successful_sc_waits=0,muldiv_waits=0;
    synapse_ddr3_system #(.BOOT_WORDS(512),.BOOT_FILE("build/posted_stores.hex"),
        .ITERATIVE_MULDIV(1),.FAST_L1(1),.DCACHE_LINES(256),.ICACHE_LINES(256),
        .STORE_BUFFER_DEPTH(DEPTH),.FAST_MULTIPLY(FAST_MULTIPLY)) dut (
        .clk(clk),.rst(rst),.calibrated(1'b1),.uart_rx(1'b1),.uart_tx(uart_tx),
        .boot_done(boot_done),.fault(fault),.core_enable(core_enable),.pc_debug(pc_debug),
        .load_req(1'b0),.load_finish(1'b0),.load_addr(32'b0),.load_data(32'b0),.load_ready(),.load_done(),
        .axi_addr(axi_addr),.arvalid(arvalid),.arready(arready),.rvalid(rvalid),.rready(rready),
        .rlast(1'b1),.rdata(rdata),.rresp(2'b0),.awvalid(awvalid),.awready(awready),
        .wvalid(wvalid),.wready(wready),.wdata(wdata),.wstrb(wstrb),
        .bvalid(bvalid),.bready(bready),.bresp(2'b0)
    );
    function automatic [12:0] ram_index(input [27:0] address);
        reg [27:0] mapped;
        begin
            mapped=address>=28'h4000000 ? address-28'h4000000+28'h10000 : address;
            if(mapped>=28'h20000) $fatal(1,"RAM address out of test range: %h",address);
            ram_index=13'(mapped>>4);
        end
    endfunction
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(!rst) begin
            if(arvalid&&arready) begin read_addr<=axi_addr;read_delay<=4;end
            else if(read_delay>1) read_delay<=read_delay-1;
            else if(read_delay==1) begin
                rdata<=ram[ram_index(read_addr)];rvalid<=1;read_delay<=0;
            end
            if(rvalid&&rready) rvalid<=0;
            if(awvalid&&awready) begin write_addr<=axi_addr;have_aw<=1;end
            if(wvalid&&wready) begin write_data<=wdata;write_strobes<=wstrb;have_w<=1;end
            if(have_aw&&have_w&&write_delay==0&&!bvalid) write_delay<=100;
            else if(write_delay>1) write_delay<=write_delay-1;
            else if(write_delay==1) begin
                for(lane=0;lane<16;lane=lane+1)
                    if(write_strobes[lane]) ram[ram_index(write_addr)][lane*8+:8]<=write_data[lane*8+:8];
                bvalid<=1;write_delay<=0;
            end
            if(bvalid&&bready) begin bvalid<=0;have_aw<=0;have_w<=0;end
            if(fault) $fatal(1,"fabric fault PC=%h stage=%h",pc_debug,dut.cpu.rf_inst0.register_file[31]);
            if(core_enable) begin
                if(dut.store_enq_fire) posted<=posted+1;
                if(dut.muldiv_wait_event) muldiv_waits<=muldiv_waits+1;
                if(dut.store_pending) begin
                    if(dut.d_hit_event) pending_hits<=pending_hits+1;
                    if(dut.direct_dreq&&!dut.dwe&&!dut.data_atomic) begin
                        pending_misses<=pending_misses+1;
                        if(dut.dbgnt) $fatal(1,"load miss granted before posted writes drained");
                    end
                    if(dut.cpu.id_ex_inst0_instr_valid_out&&
                       ((dut.cpu.id_ex_inst0_instr_id_out==INSTR_FENCE)||
                        (dut.cpu.id_ex_inst0_instr_id_out==INSTR_FENCE_I))) begin
                        if(dut.cpu.ex_stage_active||dut.retire_event)
                            $fatal(1,"fence executed/retired with pending writes");
                        if(dut.cpu.id_ex_inst0_instr_id_out==INSTR_FENCE) fence_waits<=fence_waits+1;
                        else fence_i_waits<=fence_i_waits+1;
                    end
                    if(dut.data_atomic) begin
                        if(dut.dgnt) $fatal(1,"atomic data port granted with pending writes");
                        if(!dut.cpu.mem_wait) $fatal(1,"atomic did not hold MEM with pending writes");
                        if(dut.cpu.is_lr_w) lr_waits<=lr_waits+1;
                        if(dut.cpu.is_sc_w) begin
                            sc_waits<=sc_waits+1;
                            if(!dut.cpu.sc_success) failed_sc_waits<=failed_sc_waits+1;
                            else successful_sc_waits<=successful_sc_waits+1;
                        end
                        if(dut.cpu.is_amo_w) amo_waits<=amo_waits+1;
                    end
                end
                if(ram[13'h10ff][31:0]==32'hdead)
                    $fatal(1,"program failed PC=%h stage=%h a0=%h a1=%h",pc_debug,dut.cpu.rf_inst0.register_file[31],
                           dut.cpu.rf_inst0.register_file[10],dut.cpu.rf_inst0.register_file[11]);
                if(ram[13'h10ff][31:0]==32'h600d&&!dut.store_pending) begin
                    if(posted<11||pending_hits==0||pending_misses==0||fence_waits==0||fence_i_waits==0||
                       lr_waits==0||amo_waits==0||failed_sc_waits==0||successful_sc_waits==0||muldiv_waits==0)
                        $fatal(1,"vacuous coverage post=%0d hit=%0d miss=%0d fence=%0d fi=%0d lr=%0d sc=%0d amo=%0d failedsc=%0d successsc=%0d md=%0d",
                               posted,pending_hits,pending_misses,fence_waits,fence_i_waits,lr_waits,sc_waits,amo_waits,failed_sc_waits,successful_sc_waits,muldiv_waits);
                    $display("PASS posted stores depth=%0d fastmul=%0d cycles=%0d post=%0d hit=%0d miss=%0d fence=%0d fi=%0d lr=%0d sc=%0d amo=%0d failedsc=%0d successsc=%0d md=%0d",
                             DEPTH,FAST_MULTIPLY,cycles,posted,pending_hits,pending_misses,fence_waits,fence_i_waits,
                             lr_waits,sc_waits,amo_waits,failed_sc_waits,successful_sc_waits,muldiv_waits);
                    $finish;
                end
            end
        end
    end
    initial begin
        for(n=0;n<8192;n=n+1) ram[n]=0;
        ram[13'h1020][31:0]=32'hcafed00d;
        repeat(5) @(negedge clk);rst=0;
        repeat(150000) @(negedge clk);
        $fatal(1,"timeout PC=%h stage=%h pending=%b",pc_debug,dut.cpu.rf_inst0.register_file[31],dut.store_pending);
    end
endmodule
