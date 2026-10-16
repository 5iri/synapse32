`default_nettype none
`include "memory_map.vh"
// Physical bus arbitration shared by instruction, data and page-walk accesses.
// SERIAL_BOOT=1 holds the CPU reset while the host loader writes the payload.
module synapse_ddr3_system #(
    parameter BOOT_WORDS=256, BOOT_FILE="boot.hex", SERIAL_BOOT=0,
    parameter ITERATIVE_MULDIV=0, UART_DIVISOR_SCALE=1, UART_DEFAULT_DIVISOR=10
) (
    input wire clk, rst, calibrated, uart_rx,
    output wire uart_tx, boot_done, fault, core_enable,
    output wire [31:0] pc_debug,
    input wire load_req, load_finish,
    input wire [31:0] load_addr, load_data,
    output wire load_ready, load_done,
    output wire [27:0] axi_addr,
    output wire arvalid, rready, awvalid, wvalid, bready,
    input wire arready, rvalid, rlast, awready, wready, bvalid,
    input wire [127:0] rdata,
    input wire [1:0] rresp, bresp,
    output wire [127:0] wdata,
    output wire [15:0] wstrb
);
    reg booted;
    reg [31:0] boot_index;
    reg [31:0] boot_rom[0:BOOT_WORDS-1];
    generate if(!SERIAL_BOOT) begin: rom_init
        initial $readmemh(BOOT_FILE,boot_rom);
    end endgenerate
    assign boot_done=booted;
    wire cpu_rst=rst||!booted||fault;
    assign core_enable=!cpu_rst;
    wire [31:0] instr, cpu_data, rd_addr, wr_addr, wr_data, satp;
    wire rd_en, wr_en, write_intent, immu, dmmu, sum, mxr, tlb_flush;
    wire [3:0] be;
    wire [2:0] load_type;
    wire [1:0] ipriv, dpriv;
    wire ignt, ivalid, ifault, dgnt, dvalid, dfault;
    wire timer_irq, uart_irq, plic_irq;
    reg msip;
    riscv_cpu #(.ITERATIVE_MULDIV(ITERATIVE_MULDIV)) cpu (
        .clk(clk),.rst(cpu_rst),.module_instr_in(instr),.module_read_data_in(cpu_data),
        .module_pc_out(pc_debug),.module_wr_data_out(wr_data),
        .module_mem_wr_en(wr_en),.module_mem_rd_en(rd_en),
        .module_read_addr(rd_addr),.module_write_addr(wr_addr),
        .module_write_byte_enable(be),.module_load_type(load_type),
        .module_instr_gnt_in(ignt),.module_instr_rvalid_in(ivalid),
        .module_data_gnt_in(dgnt),.module_data_rvalid_in(dvalid),
        .module_instr_page_fault_in(ifault),
        .module_load_page_fault_in(dfault&&!write_intent),
        .module_store_page_fault_in(dfault&&write_intent),
        .module_page_fault_addr_in(wr_en ? wr_addr : rd_addr),
        .module_data_write_intent_out(write_intent),
        .module_tlb_flush_out(tlb_flush),
        .module_data_mmu_enable_out(dmmu),.module_data_privilege_out(dpriv),
        .module_satp_out(satp),.module_data_sum_out(sum),.module_data_mxr_out(mxr),
        .module_instr_mmu_enable_out(immu),.module_instr_privilege_out(ipriv),
        .timer_interrupt(timer_irq),.software_interrupt(msip),.external_interrupt(plic_irq)
    );
    wire ireq, iwe, dreq, dwe, ibgnt, dbgnt, ibdone, dbdone, ifatal, dfatal;
    wire [31:0] ia, idata, da, ddata;
    wire [3:0] ibe, dbe;
    wire [31:0] bus_result;
    wire bus_error;
    sv32_bus_port #(.FETCH(1)) instr_port (
        .clk(clk),.rst(cpu_rst),.flush_tlb(tlb_flush),
        .req(!cpu_rst),.we(1'b0),.write_intent(1'b0),
        .translate(immu),.va(pc_debug),.satp(satp),.wdata(32'b0),
        .privilege(ipriv),.sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'b010),
        .gnt(ignt),.rvalid(ivalid),.page_fault(ifault),.rdata(instr),
        .bus_req(ireq),.bus_we(iwe),.bus_addr(ia),.bus_wdata(idata),.bus_be(ibe),
        .bus_gnt(ibgnt),.bus_done(ibdone),.bus_rdata(bus_result),.bus_error(bus_error),
        .fatal_error(ifatal)
    );
    sv32_bus_port data_port (
        .clk(clk),.rst(cpu_rst),.flush_tlb(tlb_flush),
        .req(rd_en||wr_en),.we(wr_en),.write_intent(write_intent),
        .translate(dmmu),.va(wr_en ? wr_addr : rd_addr),.satp(satp),.wdata(wr_data),
        .privilege(dpriv),.sum(sum),.mxr(mxr),.be(be),.load_type(load_type),
        .gnt(dgnt),.rvalid(dvalid),.page_fault(dfault),.rdata(cpu_data),
        .bus_req(dreq),.bus_we(dwe),.bus_addr(da),.bus_wdata(ddata),.bus_be(dbe),
        .bus_gnt(dbgnt),.bus_done(dbdone),.bus_rdata(bus_result),.bus_error(bus_error),
        .fatal_error(dfatal)
    );
    wire boot_req=!booted && (SERIAL_BOOT ? load_req : boot_index<BOOT_WORDS);
    wire [31:0] boot_addr=SERIAL_BOOT ? load_addr : (`INSTR_MEM_BASE+boot_index*4);
    wire [31:0] boot_data=SERIAL_BOOT ? load_data : boot_rom[boot_index[$clog2(BOOT_WORDS)-1:0]];
    // Owner 0=loader, 1=data, 2=instruction. Data takes precedence to drain MEM.
    wire [1:0] select_owner=!booted ? 2'd0 : (dreq ? 2'd1 : 2'd2);
    wire select_req=!booted ? boot_req : (dreq||ireq);
    wire [31:0] select_addr=!booted ? boot_addr : (dreq ? da : ia);
    wire [31:0] select_data=!booted ? boot_data : (dreq ? ddata : idata);
    wire select_we=!booted || (dreq ? dwe : iwe);
    wire [3:0] select_be=!booted ? 4'b1111 : (dreq ? dbe : ibe);
    wire select_ram=`IS_INSTR_MEM(select_addr)||`IS_DATA_MEM(select_addr);
    wire select_uart=`IS_UART_MEM(select_addr);
    wire select_timer=`IS_TIMER_MEM(select_addr);
    wire select_plic=`IS_PLIC_MEM(select_addr);
    wire select_msip=(select_addr==32'h02000000);
    wire select_mmio=select_uart||select_timer||select_plic||select_msip;
    reg [1:0] state, owner;
    reg [31:0] mmio_result;
    reg bad_address;
    wire bridge_ready, bridge_done, bridge_error;
    wire [31:0] bridge_result;
    wire accept=(state==0)&&bridge_ready&&calibrated&&select_req&&!fault;
    wire complete=(state==1&&bridge_done)||(state==2);
    assign bus_result=state==2 ? mmio_result : bridge_result;
    assign bus_error=bad_address||(state==1&&bridge_error);
    assign ibgnt=accept&&(select_owner==2);
    assign dbgnt=accept&&(select_owner==1);
    assign ibdone=complete&&(owner==2);
    assign dbdone=complete&&(owner==1);
    assign load_ready=accept&&(select_owner==0);
    assign load_done=complete&&(owner==0);
    reg fault_q;
    assign fault=fault_q;
    function automatic [27:0] physical;
        input [31:0] address;
        begin
            physical=`IS_INSTR_MEM(address) ? 28'(address-`INSTR_MEM_BASE) :
                     28'(address-`DATA_MEM_BASE+`INSTR_MEM_SIZE);
        end
    endfunction
    axi_word_bridge bridge (
        .clk(clk),.rst(rst),.req(accept&&select_ram),.we(select_we),
        .addr(physical(select_addr)),.data(select_data),.be(select_be),
        .ready(bridge_ready),.done(bridge_done),.error(bridge_error),.result(bridge_result),
        .axi_addr(axi_addr),.arvalid(arvalid),.arready(arready),.rready(rready),
        .rvalid(rvalid),.rlast(rlast),.rdata(rdata),.rresp(rresp),
        .awvalid(awvalid),.awready(awready),.wvalid(wvalid),.wready(wready),
        .wdata(wdata),.wstrb(wstrb),.bready(bready),.bvalid(bvalid),.bresp(bresp)
    );
    wire [31:0] timer_data, uart_data, plic_data;
    wire timer_valid, uart_valid, plic_valid;
    wire mmio_fire=accept&&select_mmio;
    always @(posedge clk) begin
        if(cpu_rst) msip<=0;
        else if(mmio_fire&&select_msip&&select_we&&select_be[0]) msip<=select_data[0];
    end
    timer timer_inst (
        .clk(clk),.rst(cpu_rst),.addr(select_addr),.write_data(select_data),
        .write_enable(mmio_fire&&select_timer&&select_we),
        .read_enable(mmio_fire&&select_timer&&!select_we),
        .read_data(timer_data),.timer_valid(timer_valid),.timer_interrupt(timer_irq)
    );
    uart #(.DIVISOR_SCALE(UART_DIVISOR_SCALE),.DEFAULT_DIVISOR(UART_DEFAULT_DIVISOR)) uart_inst (
        .clk(clk),.rst(cpu_rst),.addr(select_addr),.write_data(select_data),
        .write_enable(mmio_fire&&select_uart&&select_we),
        .read_enable(mmio_fire&&select_uart&&!select_we),
        .read_data(uart_data),.uart_valid(uart_valid),.tx(uart_tx),.rx(uart_rx),.interrupt(uart_irq)
    );
    plic plic_inst (
        .clk(clk),.rst(cpu_rst),.addr(select_addr),.write_data(select_data),
        .write_enable(mmio_fire&&select_plic&&select_we),
        .read_enable(mmio_fire&&select_plic&&!select_we),.source_irq(uart_irq),
        .read_data(plic_data),.plic_valid(plic_valid),.external_interrupt(plic_irq)
    );
    always @(posedge clk) begin
        if(rst) begin
            booted<=0; boot_index<=0; state<=0; owner<=0;
            mmio_result<=0; bad_address<=0; fault_q<=0;
        end else begin
            if(accept) begin
                owner<=select_owner; bad_address<=!select_ram&&!select_mmio;
                state<=select_ram ? 1 : 2;
                mmio_result<=select_msip ? {31'b0,msip} :
                             (select_uart ? uart_data : (select_timer ? timer_data : plic_data));
            end else if(complete) begin
                state<=0;
                if(bus_error) fault_q<=1;
                if(owner==0&&!SERIAL_BOOT&&!bus_error) begin
                    boot_index<=boot_index+1;
                    if(boot_index==BOOT_WORDS-1) booted<=1;
                end
            end
            if(SERIAL_BOOT&&load_finish&&state==0&&calibrated&&!fault) booted<=1;
            if(ifatal||dfatal) fault_q<=1;
        end
    end
endmodule
