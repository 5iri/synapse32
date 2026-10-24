`timescale 1ns/1ps
`default_nettype none
`ifndef RESET_AXI_CYCLES
`define RESET_AXI_CYCLES 20
`endif
module tb_software_reset;
    reg clk=0,reset_n=0,uart_rx=1;
    always #5 clk=~clk;
    wire uart_tx,calibrated,boot_done,fault;
    wire [31:0] pc;
    wire [15:0] dq;wire [1:0] dqs_n,dqs_p,dm;
    wire [13:0] ddr_addr;wire [2:0] ba;
    wire ras,cas,we,ddr_reset;wire [0:0] ck_p,ck_n,cke,cs_n,odt;
    localparam BIT=16;
    arty_ddr3_top #(.SERIAL_BOOT(1),.SEPARATE_CPU_CLOCK(0),.CLOCK_HZ(16000000),.BOOT_BAUD(1000000),
        .FAST_L1(1),.ICACHE_LINES(16),.DCACHE_LINES(16),.STORE_BUFFER_DEPTH(8),
        .FAST_MULTIPLY(1),.FETCH_QUEUE(1),.LOAD_FORWARDING(1),.FAST_STORE_ACK(1)) dut (
        .clk100(clk),.clk_ref200(clk),.cpu_clk50(clk),.reset_n(reset_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .calibrated(calibrated),.boot_done(boot_done),.fault(fault),.pc_debug(pc),
        .ddr3_dq(dq),.ddr3_dqs_n(dqs_n),.ddr3_dqs_p(dqs_p),.ddr3_addr(ddr_addr),.ddr3_ba(ba),
        .ddr3_ras_n(ras),.ddr3_cas_n(cas),.ddr3_we_n(we),.ddr3_reset_n(ddr_reset),
        .ddr3_ck_p(ck_p),.ddr3_ck_n(ck_n),.ddr3_cke(cke),.ddr3_cs_n(cs_n),.ddr3_dm(dm),.ddr3_odt(odt)
    );
    reg [31:0] reset_program[0:255],final_program[0:255];
    integer reset_words=0,final_words=0,reset_requests=0,reset_pulses=0,boot_events=0;
    integer keyed_accepts=0,ignored_writes=0,acknowledged_resets=0,reset_hold_cycles=0,phase=0,cycles=0;
    integer last_reset_cycle=-100,expected_reset_stores=0;
    integer tx_bytes=0,reset_blocked_cycles=0,uart_drain_wait_cycles=0;
    localparam [8*18-1:0] REBOOT_MARKER="Restarting system\n";
    localparam CPU_BIT=144;
    reg prior_boot=0,prior_local_reset=1;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(reset_n) begin
            if(fault) $fatal(1,"fabric/loader fault phase=%0d pc=%h",phase,pc);
            if(boot_done&&!prior_boot) boot_events<=boot_events+1;
            prior_boot<=boot_done;
            if(phase>0&&(!calibrated||!dut.axi_reset[1]||!dut.mig.aresetn||!dut.mig.sys_rst))
                $fatal(1,"warm reset disturbed MIG/calibration/AXI reset domain");
            if(dut.system_inst.dreq&&dut.system_inst.dwe&&dut.system_inst.da==32'h20002000&&
               dut.system_inst.ddata==32'h53333252&&dut.system_inst.dbe==4'hf&&dut.system_inst.store_pending)
                reset_blocked_cycles<=reset_blocked_cycles+1;
            if(dut.system_inst.reboot_pending&&dut.system_inst.reboot_response_done&&!dut.system_inst.uart_tx_idle)
                uart_drain_wait_cycles<=uart_drain_wait_cycles+1;
            if(dut.system_inst.mmio_fire&&dut.system_inst.select_reset&&dut.system_inst.select_we) begin
                if(dut.system_inst.reset_write) begin
                    keyed_accepts<=keyed_accepts+1;
                    if(dut.system_inst.uart_tx_idle||dut.system_inst.uart_inst.tx_fifo_count==0)
                        $fatal(1,"reset test did not queue a pending final UART marker");
                    if(dut.system_inst.store_pending||!dut.system_inst.bridge_ready||dut.mig.busy)
                        $fatal(1,"keyed reset accepted with undrained DDR/store traffic");
                    if(dut.mig.ram[512][31:0]!==32'h5eed || dut.mig.ram[520][63:32]!==32'd32)
                        $fatal(1,"older posted stores were not committed before reset acceptance");
                end else ignored_writes<=ignored_writes+1;
            end
            if(dut.system_inst.reboot_pending&&dut.system_inst.dbdone) acknowledged_resets<=acknowledged_resets+1;
            if(dut.warm_reset_request) begin
                reset_requests<=reset_requests+1;
                if(!dut.system_inst.uart_tx_idle||tx_bytes!=(reset_requests+1)*18)
                    $fatal(1,"reset truncated console marker bytes=%0d expected=%0d",tx_bytes,(reset_requests+1)*18);
                if(acknowledged_resets!=reset_requests+1)
                    $fatal(1,"reset request preceded its MMIO completion response");
                if(dut.mig.busy||dut.system_inst.store_pending) $fatal(1,"reset request while transaction owned");
            end
            if(dut.local_rst&&!dut.rst) reset_hold_cycles<=reset_hold_cycles+1;
            if(dut.local_rst&&!prior_local_reset) begin
                reset_pulses<=reset_pulses+1;last_reset_cycle<=cycles;
                if(keyed_accepts!=reset_requests||reset_requests!=reset_pulses+1)
                    $fatal(1,"wrong-key/partial write or repeated reset pulse");
            end
            prior_local_reset<=dut.local_rst;
            if(dut.local_rst&&!dut.rst&&prior_local_reset&&cycles-last_reset_cycle>=2) begin
                if(boot_done||dut.core_enable||dut.serial_loader.loader.state!=0||
                   dut.system_inst.fetch_queue.pending||dut.system_inst.fetch_queue.count!=0||
                   dut.system_inst.instr_port.state!=0||dut.system_inst.data_port.state!=0)
                    $fatal(1,"local reset state boot=%b core=%b loader=%0d pending=%b count=%0d instr=%0d data=%0d rst=%b global=%b hold=%h cycle=%0d last=%0d",boot_done,dut.core_enable,dut.serial_loader.loader.state,dut.system_inst.fetch_queue.pending,dut.system_inst.fetch_queue.count,dut.system_inst.instr_port.state,dut.system_inst.data_port.state,dut.local_rst,dut.rst,dut.warm_reset_hold,cycles,last_reset_cycle);
            end
        end
    end
    function automatic [31:0] crc_byte(input [31:0] previous,input [7:0] value);
        reg [31:0] c;integer k;begin c=previous^{24'b0,value};for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    task automatic send_byte(input [7:0] value);integer bitno;begin
        @(negedge clk);uart_rx=0;repeat(BIT)@(negedge clk);
        for(bitno=0;bitno<8;bitno=bitno+1)begin uart_rx=value[bitno];repeat(BIT)@(negedge clk);end
        uart_rx=1;repeat(BIT)@(negedge clk);
    end endtask
    task automatic send_word(input [31:0] value);integer b;begin for(b=0;b<4;b=b+1)send_byte(value[b*8+:8]);end endtask
    task automatic upload(input bit final_image);integer n,b,words;reg[31:0] value,crc;reg[7:0] reply;begin
        words=final_image?final_words:reset_words;crc=32'hffffffff;
        send_byte("S");send_byte("3");send_byte("2");send_byte("!");send_word(32'(words*4));
        for(n=0;n<words;n=n+1)begin
            value=final_image?final_program[n]:reset_program[n];
            for(b=0;b<4;b=b+1)begin send_byte(value[b*8+:8]);crc=crc_byte(crc,value[b*8+:8]);end
        end
        send_word(~crc);
        // The boot response must finish before CPU/UART ownership switches.
        wait(!uart_tx);repeat(BIT+BIT/2)@(negedge clk);
        for(b=0;b<8;b=b+1)begin reply[b]=uart_tx;repeat(BIT)@(negedge clk);end
        if(reply!==8'h4b) $fatal(1,"CRC-verified upload response got %h",reply);
        repeat(BIT*2)@(negedge clk);
    end endtask
    // Decode the real CPU console stream, independently of the UART's status
    // registers. Loader K replies happen before boot_done and are ignored here.
    reg [7:0] console_byte;
    integer console_bit;
    initial forever begin
        @(negedge uart_tx);
        if(boot_done) begin
            repeat(CPU_BIT+CPU_BIT/2) @(negedge clk);
            for(console_bit=0;console_bit<8;console_bit=console_bit+1) begin
                console_byte[console_bit]=uart_tx;
                repeat(CPU_BIT) @(negedge clk);
            end
            if(!uart_tx||console_byte!==REBOOT_MARKER[(17-(tx_bytes%18))*8+:8])
                $fatal(1,"console marker byte%0d got%h",tx_bytes,console_byte);
            tx_bytes=tx_bytes+1;
        end
    end
    integer n;
    initial begin
        $readmemh("build/software-reset-program.hex",reset_program);
        $readmemh("build/software-reset-final.hex",final_program);
        reset_words=reset_program[255];final_words=final_program[255];
        repeat(6)@(negedge clk);reset_n=1;wait(calibrated);repeat(20)@(negedge clk);phase=1;
        upload(0);wait(reset_pulses==1);wait(!dut.local_rst);repeat(12)@(negedge clk);
        if(boot_done||dut.serial_loader.loader.state!=0) $fatal(1,"first reset failed to rearm loader");
        upload(0);wait(reset_pulses==2);wait(!dut.local_rst);repeat(12)@(negedge clk);
        upload(1);wait(boot_done);wait(dut.mig.ram[512][63:32]==32'h600d);repeat(80)@(negedge clk);
        if(reset_requests!=2||reset_pulses!=2||keyed_accepts!=2||ignored_writes!=8||boot_events!=3||acknowledged_resets!=2||reset_hold_cycles!=16)
            $fatal(1,"reset/boot accounting request%0d pulse%0d key%0d ignored%0d boots%0d ack%0d hold%0d",reset_requests,reset_pulses,keyed_accepts,ignored_writes,boot_events,acknowledged_resets,reset_hold_cycles);
        if(tx_bytes!=36||reset_blocked_cycles==0||uart_drain_wait_cycles==0)
            $fatal(1,"missing UART/store drain coverage bytes=%0d blocked=%0d uartwait=%0d",tx_bytes,reset_blocked_cycles,uart_drain_wait_cycles);
        if(dut.mig.ram[512][31:0]!==32'h5eed) $fatal(1,"MIG memory did not survive local reset");
        $display("PASS SOFTWARE_RESET axi_latency=%0d boots=%0d resets=%0d ignored_writes=%0d hold_cycles=%0d tx_bytes=%0d store_wait=%0d uart_wait=%0d cycles=%0d",`RESET_AXI_CYCLES,boot_events,reset_pulses,ignored_writes,reset_hold_cycles,tx_bytes,reset_blocked_cycles,uart_drain_wait_cycles,cycles);
        $finish;
    end
    initial begin repeat(500000)@(negedge clk);$fatal(1,"timeout phase=%0d pc=%h",phase,pc);end
endmodule

// Behavioral MIG boundary: DDR/calibration and AXI reset state are separate
// from the local CPU reset being tested. A completed old request cannot linger.
module mig_arty(
 input wire sys_clk_i,clk_ref_i,sys_rst,aresetn,
 output wire ui_clk,output reg ui_clk_sync_rst=1,init_calib_complete=0,
 inout wire[15:0]ddr3_dq,inout wire[1:0]ddr3_dqs_n,ddr3_dqs_p,
 output wire[13:0]ddr3_addr,output wire[2:0]ddr3_ba,
 output wire ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
 output wire[0:0]ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,output wire[1:0]ddr3_dm,
 input wire[3:0]s_axi_awid,input wire[27:0]s_axi_awaddr,input wire[7:0]s_axi_awlen,input wire[2:0]s_axi_awsize,
 input wire[1:0]s_axi_awburst,input wire s_axi_awlock,input wire[3:0]s_axi_awcache,input wire[2:0]s_axi_awprot,input wire[3:0]s_axi_awqos,s_axi_awregion,
 input wire s_axi_awvalid,output wire s_axi_awready,input wire[127:0]s_axi_wdata,input wire[15:0]s_axi_wstrb,input wire s_axi_wlast,s_axi_wvalid,output wire s_axi_wready,
 output wire[3:0]s_axi_bid,output wire[1:0]s_axi_bresp,output reg s_axi_bvalid=0,input wire s_axi_bready,
 input wire[3:0]s_axi_arid,input wire[27:0]s_axi_araddr,input wire[7:0]s_axi_arlen,input wire[2:0]s_axi_arsize,
 input wire[1:0]s_axi_arburst,input wire s_axi_arlock,input wire[3:0]s_axi_arcache,input wire[2:0]s_axi_arprot,input wire[3:0]s_axi_arqos,s_axi_arregion,
 input wire s_axi_arvalid,output wire s_axi_arready,output wire[3:0]s_axi_rid,output reg[127:0]s_axi_rdata=0,output wire[1:0]s_axi_rresp,output wire s_axi_rlast,output reg s_axi_rvalid=0,input wire s_axi_rready,
 input wire app_sr_req,app_ref_req,app_zq_req,output wire app_sr_active,app_ref_ack,app_zq_ack,output wire[11:0]device_temp
);
 assign ui_clk=sys_clk_i;assign ddr3_reset_n=sys_rst;
 assign ddr3_addr=0;assign ddr3_ba=0;assign ddr3_ras_n=1;assign ddr3_cas_n=1;assign ddr3_we_n=1;
 assign ddr3_ck_p=0;assign ddr3_ck_n=0;assign ddr3_cke=0;assign ddr3_cs_n=0;assign ddr3_odt=0;assign ddr3_dm=0;
 assign app_sr_active=0;assign app_ref_ack=0;assign app_zq_ack=0;assign device_temp=0;
 assign s_axi_bid=0;assign s_axi_bresp=0;assign s_axi_rid=0;assign s_axi_rresp=0;assign s_axi_rlast=1;
 reg[127:0]ram[0:1023];reg have_aw=0,have_w=0;reg[27:0]read_addr,write_addr;reg[127:0]write_data;reg[15:0]strobes;
 integer read_delay=0,write_delay=0,cal_count=0,n,lane;
 wire busy=have_aw||have_w||s_axi_bvalid||s_axi_rvalid||read_delay!=0||write_delay!=0;
 assign s_axi_arready=aresetn&&!s_axi_rvalid&&read_delay==0;
 assign s_axi_awready=aresetn&&!have_aw&&!s_axi_bvalid;assign s_axi_wready=aresetn&&!have_w&&!s_axi_bvalid;
 function automatic[9:0]index(input[27:0]address);reg[27:0]mapped;begin mapped=address>=28'h4000000 ? address-28'h4000000+28'h2000:address;if(mapped>=28'h4000)$fatal(1,"RAM range%h",address);index=10'(mapped>>4);end endfunction
 initial begin for(n=0;n<1024;n=n+1)ram[n]=0;end
 always@(posedge sys_clk_i)begin
  if(!sys_rst)begin cal_count<=0;ui_clk_sync_rst<=1;init_calib_complete<=0;end
  else if(cal_count<5)begin cal_count<=cal_count+1;ui_clk_sync_rst<=1;end
  else begin ui_clk_sync_rst<=0;init_calib_complete<=1;end
  if(!aresetn)begin have_aw<=0;have_w<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;read_delay<=0;write_delay<=0;end
  else begin
   if(s_axi_arvalid&&s_axi_arready)begin read_addr<=s_axi_araddr;read_delay<=`RESET_AXI_CYCLES;end
   else if(read_delay>1)read_delay<=read_delay-1;
   else if(read_delay==1)begin s_axi_rdata<=ram[index(read_addr)];s_axi_rvalid<=1;read_delay<=0;end
   if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
   if(s_axi_awvalid&&s_axi_awready)begin write_addr<=s_axi_awaddr;have_aw<=1;end
   if(s_axi_wvalid&&s_axi_wready)begin write_data<=s_axi_wdata;strobes<=s_axi_wstrb;have_w<=1;end
   if(have_aw&&have_w&&write_delay==0&&!s_axi_bvalid)write_delay<=`RESET_AXI_CYCLES;
   else if(write_delay>1)write_delay<=write_delay-1;
   else if(write_delay==1)begin for(lane=0;lane<16;lane=lane+1)if(strobes[lane])ram[index(write_addr)][lane*8+:8]<=write_data[lane*8+:8];s_axi_bvalid<=1;write_delay<=0;end
   if(s_axi_bvalid&&s_axi_bready)begin s_axi_bvalid<=0;have_aw<=0;have_w<=0;end
  end
 end
endmodule
