`timescale 1ns/1ps
`default_nettype none
module tb_fetch_throughput #(parameter FETCH_QUEUE=0, EXPECT_INTERVAL=0);
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
    wire arready=!rvalid&&(read_delay==0),awready=!have_aw&&!bvalid,wready=!have_w&&!bvalid;
    reg [27:0] read_addr,write_addr;
    reg [127:0] write_data;
    reg [15:0] write_strobes;
    reg [127:0] ram[0:1023];
    integer read_delay=0,write_delay=0,n,lane,cycles=0;
    integer grants=0,responses=0,retired=0,valids=0;
    integer last_g=-1,last_r=-1,last_x=-1,min_g=999,max_g=0,min_r=999,max_r=0,min_x=999,max_x=0;
    synapse_ddr3_system #(.BOOT_WORDS(256),.BOOT_FILE("build/fetch-throughput.hex"),
        .ITERATIVE_MULDIV(1),.FAST_L1(1),.DCACHE_LINES(256),.ICACHE_LINES(256),
        .STORE_BUFFER_DEPTH(0),.FAST_MULTIPLY(0)
`ifdef FETCH_QUEUE_INTERFACE
        ,.FETCH_QUEUE(FETCH_QUEUE)
`endif
    ) dut (
        .clk(clk),.rst(rst),.calibrated(1'b1),.uart_rx(1'b1),.uart_tx(uart_tx),
        .boot_done(boot_done),.fault(fault),.core_enable(core_enable),.pc_debug(pc_debug),
        .load_req(1'b0),.load_finish(1'b0),.load_addr(32'b0),.load_data(32'b0),.load_ready(),.load_done(),
        .axi_addr(axi_addr),.arvalid(arvalid),.arready(arready),.rvalid(rvalid),.rready(rready),
        .rlast(1'b1),.rdata(rdata),.rresp(2'b0),.awvalid(awvalid),.awready(awready),
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
    function automatic region(input [31:0] pc);
        region=pc>=32'h80000100&&pc<32'h80000200;
    endfunction
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(!rst) begin
            if(arvalid&&arready) begin read_addr<=axi_addr;read_delay<=4;end
            else if(read_delay>1) read_delay<=read_delay-1;
            else if(read_delay==1) begin rdata<=ram[ram_index(read_addr)];rvalid<=1;read_delay<=0;end
            if(rvalid&&rready) rvalid<=0;
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
            if(fault) $fatal(1,"fabric fault PC=%h",pc_debug);
            if(core_enable&&dut.cpu.rf_inst0.register_file[31]==2) begin
                if(dut.ignt&&region(dut.instr_port.va)) begin
                    grants<=grants+1;
                    if(last_g>=0) begin
                        if(cycles-last_g<min_g) min_g<=cycles-last_g;
                        if(cycles-last_g>max_g) max_g<=cycles-last_g;
                    end
                    last_g<=cycles;
                    $display("S32_FETCH_TRACE grant cycle=%0d pc=%h",cycles,dut.instr_port.va);
                end
                if(dut.instr_port.rvalid&&region(dut.instr_port.va_q)) begin
                    responses<=responses+1;
                    if(last_r>=0) begin
                        if(cycles-last_r<min_r) min_r<=cycles-last_r;
                        if(cycles-last_r>max_r) max_r<=cycles-last_r;
                    end
                    last_r<=cycles;
                    $display("S32_FETCH_TRACE response cycle=%0d pc=%h",cycles,dut.instr_port.va_q);
                end
                if(dut.ivalid&&region(pc_debug)) valids<=valids+1;
                if(dut.retire_event&&region(dut.cpu.id_ex_inst0_pc_out)) begin
                    retired<=retired+1;
                    if(last_x>=0) begin
                        if(cycles-last_x<min_x) min_x<=cycles-last_x;
                        if(cycles-last_x>max_x) max_x<=cycles-last_x;
                    end
                    last_x<=cycles;
                    $display("S32_FETCH_TRACE retire cycle=%0d pc=%h",cycles,dut.cpu.id_ex_inst0_pc_out);
                end
            end
            if(core_enable&&ram[512][63:32]==32'h600d) begin
                if(ram[512][31:0]!=320) $fatal(1,"ADDI execution duplicated/lost: got %0d expected320",ram[512][31:0]);
                if(grants!=64||responses!=64||retired!=64) $fatal(1,"incomplete warm window grants=%0d rsp=%0d retired=%0d",grants,responses,retired);
                if(EXPECT_INTERVAL>0&&(min_g!=EXPECT_INTERVAL||max_g!=EXPECT_INTERVAL||
                   min_r!=EXPECT_INTERVAL||max_r!=EXPECT_INTERVAL||min_x!=EXPECT_INTERVAL||max_x!=EXPECT_INTERVAL))
                    $fatal(1,"cadence differs: grants=%0d..%0d responses=%0d..%0d retire=%0d..%0d expected%0d",min_g,max_g,min_r,max_r,min_x,max_x,EXPECT_INTERVAL);
                $display("S32_FETCH_THROUGHPUT {\"fetch_queue\":%0d,\"grants\":%0d,\"responses\":%0d,\"retired\":%0d,\"cpu_valid_cycles\":%0d,\"grant_interval_min\":%0d,\"grant_interval_max\":%0d,\"response_interval_min\":%0d,\"response_interval_max\":%0d,\"retire_interval_min\":%0d,\"retire_interval_max\":%0d}",
                         FETCH_QUEUE,grants,responses,retired,valids,min_g,max_g,min_r,max_r,min_x,max_x);
                $finish;
            end
        end
    end
    initial begin
        for(n=0;n<1024;n=n+1) ram[n]=0;
        repeat(5) @(negedge clk);rst=0;
        repeat(30000) @(negedge clk);
        $fatal(1,"timeout PC=%h pass=%0d",pc_debug,dut.cpu.rf_inst0.register_file[31]);
    end
endmodule
