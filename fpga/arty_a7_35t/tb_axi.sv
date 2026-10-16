`timescale 1ns/1ps
`default_nettype none
// Independent, single-beat AXI RAM with independently stalled address/data
// channels and delayed read/write responses. This is not a DDR3 PHY model.
module tb_axi #(parameter ERROR_KIND=0, DCACHE_LINES=256);
    reg clk=0, rst=1, calibrated=0;
    always #5 clk=~clk;
    wire [27:0] addr;
    wire arvalid,rready,awvalid,wvalid,bready;
    reg arready,rvalid=0,awready,wready,bvalid=0;
    reg [127:0] rdata=0;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire uart_tx,boot_done,fault,core_enable;
    wire [31:0] pc;
    reg [27:0] saved_aw, saved_ar;
    synapse_ddr3_system #(.ITERATIVE_MULDIV(1),.DCACHE_LINES(DCACHE_LINES)) dut (
        .clk(clk),.rst(rst),.calibrated(calibrated),.uart_tx(uart_tx),.uart_rx(1'b1),
        .load_req(1'b0),.load_finish(1'b0),.load_addr(32'b0),.load_data(32'b0),.load_ready(),.load_done(),
        .boot_done(boot_done),.fault(fault),.core_enable(core_enable),.pc_debug(pc),
        .axi_addr(addr),.arvalid(arvalid),.arready(arready),.rvalid(rvalid),
        .rlast(1'b1),.rdata(rdata),
        .rresp((ERROR_KIND==1 && saved_ar>=28'h4000000) ? 2'b10 : 2'b00),.rready(rready),
        .awvalid(awvalid),.awready(awready),.wvalid(wvalid),.wready(wready),
        .wdata(wdata),.wstrb(wstrb),.bvalid(bvalid),.bready(bready),
        .bresp((ERROR_KIND==2 && saved_aw>=28'h4000000) ? 2'b10 : 2'b00)
    );
    function automatic [27:0] local_addr(input [27:0] address);
        local_addr=address>=28'h4000000 ? address-28'h4000000+28'h80000 : address;
    endfunction
    reg [127:0] ram[0:98303];
    reg have_aw=0,have_w=0;
    reg [127:0] saved_w;
    reg [15:0] saved_strb;
    integer ticks=0, read_delay=0, write_delay=0, i;
    integer fetches=0, reads=0, writes=0, advances=0, waits=0, fault_cycles=0;
    reg [31:0] old_pc;
    reg [31:0] old_regs[0:31];
    reg old_enable=0, old_boot=0;
    always @(*) begin
        arready=(read_delay==0)&&!rvalid&&(ticks%7==2);
        awready=!have_aw&&!bvalid&&(ticks%5==1);
        wready=!have_w&&!bvalid&&(ticks%11==3);
    end
    always @(posedge clk) begin
        ticks<=ticks+1;
        if(!rst) begin
            if(dut.mmio_fire && dut.bridge.req) $fatal(1,"MMIO reached cached RAM bridge");
            if(arvalid&&arready) begin
                saved_ar<=addr; read_delay<=3+(ticks%9);
                if(addr<28'h4000000) fetches<=fetches+1; else reads<=reads+1;
                if(local_addr(addr)>=28'h180000) $fatal(1,"AXI RAM read out of range");
                if(addr[3:0]!=0) $fatal(1,"Unaligned AXI read");
            end else if(read_delay>1) read_delay<=read_delay-1;
            else if(read_delay==1) begin
                rdata<=ram[local_addr(saved_ar)>>4]; rvalid<=1; read_delay<=0;
            end
            if(rvalid&&rready) rvalid<=0;
            if(awvalid&&awready) begin saved_aw<=addr; have_aw<=1; end
            if(wvalid&&wready) begin saved_w<=wdata; saved_strb<=wstrb; have_w<=1; end
            if(have_aw&&have_w&&write_delay==0&&!bvalid) begin
                if(local_addr(saved_aw)>=28'h180000) $fatal(1,"AXI RAM write out of range");
                if(saved_aw[3:0]!=0) $fatal(1,"Unaligned AXI write");
                for(i=0;i<16;i=i+1)
                    if(saved_strb[i]) ram[local_addr(saved_aw)>>4][i*8+:8]<=saved_w[i*8+:8];
                write_delay<=5; writes<=writes+1;
            end else if(write_delay>1) write_delay<=write_delay-1;
            else if(write_delay==1) begin write_delay<=0; bvalid<=1; end
            if(bvalid&&bready) begin bvalid<=0;have_aw<=0;have_w<=0;end
            if(fault) begin
                if(ERROR_KIND==0) $fatal(1,"Bridge entered fault at PC=%h",pc);
                if(core_enable) $fatal(1,"CPU advanced after an AXI error");
                fault_cycles<=fault_cycles+1;
                if(fault_cycles==30) begin
                    $display("PASS: AXI response fault %0d halted CPU", ERROR_KIND);
                    $finish;
                end
            end
            if(boot_done) begin
                if(dut.ivalid||dut.dvalid) advances<=advances+1; else waits<=waits+1;

            end
            old_pc<=pc;old_enable<=core_enable;old_boot<=boot_done;
            for(i=0;i<32;i=i+1) old_regs[i]<=dut.cpu.rf_inst0.register_file[i];
            if(ram[16'h8004][31:0]==32'hdead) $fatal(1,"CPU smoke program failed PC=%h",pc);
            if(ERROR_KIND==0 && ram[16'h8004][31:0]==32'h600d) begin
                if(ram[16'h8000][31:0]!==32'h12345678 ||
                   ram[16'h8000][47:40]!==8'h80 || ram[16'h8000][127:120]!==8'h80 ||
                   ram[16'h8000][95:80]!==16'h8765 || ram[16'h8002][31:0]!==32'd28 ||
                   ram[17'h17fff][127:96]!==32'h55aa33cc || ram[17'h7fff][127:96]!==32'h55aa33cc)
                    $fatal(1,"DDR memory contents mismatch");
                if(reads<5||waits<100||fetches<20) $fatal(1,"Insufficient coverage");
                $display("PASS: DDR AXI CPU smoke: fetches=%0d reads=%0d writes=%0d advances=%0d waits=%0d",fetches,reads,writes,advances,waits);
                $finish;
            end
        end
    end
    initial begin
        for(i=0;i<98304;i=i+1) ram[i]=0;
        #100; rst=0; #100;calibrated=1;
        #5000000;$fatal(1,"Timeout PC=%h x31=%h",pc,dut.cpu.rf_inst0.register_file[31]);
    end
endmodule
