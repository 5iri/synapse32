`default_nettype none
`include "memory_map.vh"
// Physical bus arbitration shared by instruction, data and page-walk accesses.
// SERIAL_BOOT=1 holds the CPU reset while the host loader writes the payload.
module synapse_ddr3_system #(
    parameter BOOT_WORDS=256, BOOT_FILE="boot.hex", SERIAL_BOOT=0,
    parameter ITERATIVE_MULDIV=0, UART_DIVISOR_SCALE=1, UART_DEFAULT_DIVISOR=10,
    parameter DCACHE_LINES=256, ICACHE_LINES=256, FAST_L1=0,
    parameter STORE_BUFFER_DEPTH=0, FAST_MULTIPLY=0, FETCH_QUEUE=0,
    parameter LOAD_FORWARDING=0, FAST_STORE_ACK=0
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
    wire store_pending, store_queue_fault, data_atomic;
    wire retire_event, fetch_wait_event, data_wait_event, muldiv_wait_event, fence_wait_event;
    wire i_hit_event, i_miss_event, i_tlb_miss_event;
    wire d_hit_event, d_miss_event, d_tlb_miss_event;
    wire instr_consume, instr_redirect, instr_access_fault;
    wire [31:0] instr_redirect_pc;
    reg msip;
    initial begin
        if(STORE_BUFFER_DEPTH<0 || STORE_BUFFER_DEPTH>8 || (STORE_BUFFER_DEPTH>0&&!FAST_L1))
            $fatal(1,"Store queue requires FAST_L1 and depth 1..8, or zero to disable");
    end
    riscv_cpu #(.ITERATIVE_MULDIV(ITERATIVE_MULDIV),.FAST_MULTIPLY(FAST_MULTIPLY),
                .EXTERNAL_STORE_BUFFER(STORE_BUFFER_DEPTH>0),.FETCH_QUEUE(FETCH_QUEUE),
                .LOAD_FORWARDING(LOAD_FORWARDING)) cpu (
        .clk(clk),.rst(cpu_rst),.module_instr_in(instr),.module_read_data_in(cpu_data),
        .module_pc_out(pc_debug),.module_wr_data_out(wr_data),
        .module_mem_wr_en(wr_en),.module_mem_rd_en(rd_en),
        .module_read_addr(rd_addr),.module_write_addr(wr_addr),
        .module_write_byte_enable(be),.module_load_type(load_type),
        .module_instr_gnt_in(FETCH_QUEUE ? 1'b0 : ignt),.module_instr_rvalid_in(ivalid),
        .module_instr_consume_out(instr_consume),.module_instr_redirect_out(instr_redirect),
        .module_instr_redirect_pc_out(instr_redirect_pc),
        .module_instr_access_fault_in(instr_access_fault),
        .module_data_gnt_in(dgnt),.module_data_rvalid_in(dvalid),
        .module_instr_page_fault_in(ifault),
        .module_load_page_fault_in(dfault&&!write_intent),
        .module_store_page_fault_in(dfault&&write_intent),
        .module_page_fault_addr_in(wr_en ? wr_addr : rd_addr),
        .module_data_write_intent_out(write_intent),
        .module_store_pending_in(store_pending),.module_data_atomic_out(data_atomic),
        .module_retire_event_out(retire_event),.module_fetch_wait_out(fetch_wait_event),
        .module_data_wait_out(data_wait_event),.module_muldiv_wait_out(muldiv_wait_event),
        .module_fence_wait_out(fence_wait_event),
        .module_tlb_flush_out(tlb_flush),
        .module_data_mmu_enable_out(dmmu),.module_data_privilege_out(dpriv),
        .module_satp_out(satp),.module_data_sum_out(sum),.module_data_mxr_out(mxr),
        .module_instr_mmu_enable_out(immu),.module_instr_privilege_out(ipriv),
        .timer_interrupt(timer_irq),.software_interrupt(msip),.external_interrupt(plic_irq)
    );
    wire ireq, iwe, dreq, dwe, ibgnt, dbgnt, ibdone, dbdone, ifatal, dfatal;
    wire ifetch_bus;
    wire [31:0] ia, idata, da, ddata;
    wire [3:0] ibe, dbe;
    wire [31:0] bus_result;
    wire bus_error;
    wire [127:0] bridge_read_line;
    wire completed_ram_store;
    wire l1_snoop, l1_snoop_error;
    wire [31:0] l1_snoop_addr, l1_snoop_data;
    wire [3:0] l1_snoop_be;
    reg [31:0] transaction_addr_q, transaction_data_q;
    reg [3:0] transaction_be_q;
    reg transaction_we_q, transaction_ram_q;
    wire fetch_req, fetch_cancel, fetch_valid, fetch_page_fault, fetch_access_fault;
    wire [31:0] fetch_pc, fetch_word;
    wire port_valid, port_page_fault, port_access_fault;
    wire [31:0] port_word;
    instruction_fetch_queue fetch_queue (
        .clk(clk),.rst(cpu_rst||!FETCH_QUEUE),.consume(instr_consume),.redirect(instr_redirect),
        .redirect_pc(instr_redirect_pc),.cpu_pc(pc_debug),.flush_tlb(tlb_flush),
        .translate(immu),.privilege(ipriv),.satp(satp),
        .valid(fetch_valid),.instruction(fetch_word),.head_pc(),
        .page_fault(fetch_page_fault),.access_fault(fetch_access_fault),
        .req(fetch_req),.request_pc(fetch_pc),.cancel(fetch_cancel),
        .gnt(ignt),.rvalid(port_valid),.response_data(port_word),
        .response_page_fault(port_page_fault),.response_access_fault(port_access_fault)
    );
    assign ivalid=FETCH_QUEUE ? fetch_valid : port_valid;
    assign instr=FETCH_QUEUE ? fetch_word : port_word;
    assign ifault=FETCH_QUEUE ? fetch_page_fault : port_page_fault;
    assign instr_access_fault=FETCH_QUEUE ? fetch_access_fault : 1'b0;
    sv32_bus_port #(.FETCH(1),.CACHE_LINES(FAST_L1 ? ICACHE_LINES : 0),
                    .PIPELINED_FETCH(FETCH_QUEUE)) instr_port (
        .clk(clk),.rst(cpu_rst),.flush_tlb(tlb_flush),
        .fetch_cancel(FETCH_QUEUE ? fetch_cancel : 1'b0),
        .req(FETCH_QUEUE ? fetch_req : !cpu_rst),.we(1'b0),.write_intent(1'b0),
        .translate(immu),.va(FETCH_QUEUE ? fetch_pc : pc_debug),.satp(satp),.wdata(32'b0),
        .privilege(ipriv),.sum(1'b0),.mxr(1'b0),.be(4'b0),.load_type(3'b010),
        .gnt(ignt),.rvalid(port_valid),.page_fault(port_page_fault),.rdata(port_word),
        .access_fault(port_access_fault),
        .bus_req(ireq),.bus_we(iwe),.bus_addr(ia),.bus_wdata(idata),.bus_be(ibe),
        .bus_fetch(ifetch_bus),
        .bus_gnt(ibgnt),.bus_done(ibdone),.bus_rdata(bus_result),.bus_line(bridge_read_line),.bus_error(bus_error),
        .snoop(l1_snoop),.snoop_addr(l1_snoop_addr),.snoop_data(l1_snoop_data),
        .snoop_be(l1_snoop_be),.snoop_error(l1_snoop_error),
        .cache_hit_event(i_hit_event),.cache_miss_event(i_miss_event),.tlb_miss_event(i_tlb_miss_event),
        .fatal_error(ifatal)
    );
    sv32_bus_port #(.CACHE_LINES(FAST_L1 ? DCACHE_LINES : 0),
                    .EARLY_STORE_RESPONSE(FAST_STORE_ACK)) data_port (
        .clk(clk),.rst(cpu_rst),.flush_tlb(tlb_flush),.fetch_cancel(1'b0),
        .req((rd_en||wr_en)&&!(store_pending&&data_atomic)),.we(wr_en),.write_intent(write_intent),
        .translate(dmmu),.va(wr_en ? wr_addr : rd_addr),.satp(satp),.wdata(wr_data),
        .privilege(dpriv),.sum(sum),.mxr(mxr),.be(be),.load_type(load_type),
        .gnt(dgnt),.rvalid(dvalid),.page_fault(dfault),.rdata(cpu_data),
        .bus_req(dreq),.bus_we(dwe),.bus_addr(da),.bus_wdata(ddata),.bus_be(dbe),
        .bus_fetch(),
        .bus_gnt(dbgnt),.bus_done(dbdone),.bus_rdata(bus_result),.bus_line(bridge_read_line),.bus_error(bus_error),
        .snoop(l1_snoop),.snoop_addr(l1_snoop_addr),.snoop_data(l1_snoop_data),
        .snoop_be(l1_snoop_be),.snoop_error(l1_snoop_error),
        .cache_hit_event(d_hit_event),.cache_miss_event(d_miss_event),.tlb_miss_event(d_tlb_miss_event),
        .fatal_error(dfatal)
    );
    wire boot_req=!booted && (SERIAL_BOOT ? load_req : boot_index<BOOT_WORDS);
    wire [31:0] boot_addr=SERIAL_BOOT ? load_addr : (`INSTR_MEM_BASE+boot_index*4);
    wire [31:0] boot_data=SERIAL_BOOT ? load_data : boot_rom[boot_index[$clog2(BOOT_WORDS)-1:0]];
    // Owner 0=loader, 1=unbuffered data, 2=instruction, 3=queued RAM store.
    // Hits remain local. Misses/walks/MMIO wait for older posted stores.
    wire postable_store=(STORE_BUFFER_DEPTH>0)&&dreq&&dwe&&!data_atomic&&
                         (`IS_INSTR_MEM(da)||`IS_DATA_MEM(da));
    wire direct_dreq=dreq&&!postable_store;
    wire store_enq_ready, store_enq_fire, queue_bus_req;
    wire [31:0] queue_bus_addr, queue_bus_data;
    wire [3:0] queue_bus_be;
    reg posted_done_q;
    // Do not enqueue while an earlier read is in flight: this prevents a stale
    // I refill and avoids two writes to a cache's BRAM fill/snoop port.
    wire store_enq_req=postable_store&&booted&&!cpu_rst&&
                       !(state==1&&!transaction_we_q);
    wire lower_read_allowed=!store_pending&&!store_enq_fire;
    wire [1:0] select_owner=!booted ? 2'd0 : (queue_bus_req ? 2'd3 : (direct_dreq ? 2'd1 : 2'd2));
    wire select_req=!booted ? boot_req :
                    (queue_bus_req||(lower_read_allowed&&(direct_dreq||ireq)));
    wire [31:0] select_addr=!booted ? boot_addr : (queue_bus_req ? queue_bus_addr : (direct_dreq ? da : ia));
    wire [31:0] select_data=!booted ? boot_data : (queue_bus_req ? queue_bus_data : (direct_dreq ? ddata : idata));
    wire select_we=!booted || queue_bus_req || (direct_dreq ? dwe : iwe);
    wire [3:0] select_be=!booted ? 4'b1111 : (queue_bus_req ? queue_bus_be : (direct_dreq ? dbe : ibe));
    wire select_ram=`IS_INSTR_MEM(select_addr)||`IS_DATA_MEM(select_addr);
    wire select_uart=`IS_UART_MEM(select_addr);
    wire select_timer=`IS_TIMER_MEM(select_addr);
    wire select_plic=`IS_PLIC_MEM(select_addr);
    wire select_msip=(select_addr==32'h02000000);
    wire select_perf=(select_addr[31:12]==20'h20001);
    wire select_mmio=select_uart||select_timer||select_plic||select_msip||select_perf;
    reg [1:0] state, owner;
    reg [31:0] mmio_result;
    reg bad_address;
    wire bridge_ready, bridge_done, bridge_error;
    wire [31:0] bridge_result;
    wire bridge_read_wait, bridge_write_wait;
    wire accept=(state==0)&&bridge_ready&&calibrated&&select_req&&!fault;
    wire complete=(state==1&&bridge_done)||(state==2);
    assign completed_ram_store=complete&&transaction_ram_q&&transaction_we_q;
    assign bus_result=state==2 ? mmio_result : bridge_result;
    assign bus_error=bad_address||(state==1&&bridge_error);
    assign ibgnt=accept&&(select_owner==2);
    assign dbgnt=store_enq_fire||(accept&&(select_owner==1));
    assign ibdone=complete&&(owner==2);
    assign dbdone=posted_done_q||(complete&&(owner==1));
    assign load_ready=accept&&(select_owner==0);
    assign load_done=complete&&(owner==0);
    reg fault_q;
    assign fault=fault_q;
    assign l1_snoop=store_enq_fire||(completed_ram_store&&(owner!=3));
    assign l1_snoop_addr=store_enq_fire ? da : transaction_addr_q;
    assign l1_snoop_data=store_enq_fire ? ddata : transaction_data_q;
    assign l1_snoop_be=store_enq_fire ? dbe : transaction_be_q;
    assign l1_snoop_error=!store_enq_fire&&bus_error;
    always @(posedge clk) begin
        if(cpu_rst) posted_done_q<=0;
        else posted_done_q<=store_enq_fire;
    end
    generate if(STORE_BUFFER_DEPTH>0) begin: buffered_stores
        ordered_write_buffer #(.DEPTH(STORE_BUFFER_DEPTH)) queue (
            .clk(clk),.rst(cpu_rst),.enq_req(store_enq_req),.enq_addr(da),.enq_data(ddata),.enq_be(dbe),
            .enq_ready(store_enq_ready),.enq_fire(store_enq_fire),.pending(store_pending),
            .bus_req(queue_bus_req),.bus_addr(queue_bus_addr),.bus_data(queue_bus_data),.bus_be(queue_bus_be),
            .bus_gnt(accept&&(select_owner==3)),.bus_done(complete&&(owner==3)),
            .bus_error(bus_error),.fault(store_queue_fault)
        );
    end else begin: direct_stores
        assign store_enq_ready=0;assign store_enq_fire=0;assign store_pending=0;
        assign queue_bus_req=0;assign queue_bus_addr=0;assign queue_bus_data=0;assign queue_bus_be=0;
        assign store_queue_fault=0;
    end endgenerate
    function automatic [27:0] physical;
        input [31:0] address;
        begin
            physical=`IS_INSTR_MEM(address) ? 28'(address-`INSTR_MEM_BASE) :
                     28'(address-`DATA_MEM_BASE+`INSTR_MEM_SIZE);
        end
    endfunction
    axi_word_bridge #(.CACHE_LINES(FAST_L1 ? 0 : DCACHE_LINES),
                      .ICACHE_LINES(FAST_L1 ? 0 : ICACHE_LINES)) bridge (
        .clk(clk),.rst(rst),.req(accept&&select_ram),.we(select_we),
        .cache_read(booted&&(select_owner==1)),
        .cache_instr(booted&&(select_owner==2)&&ifetch_bus),
        .addr(physical(select_addr)),.data(select_data),.be(select_be),
        .ready(bridge_ready),.done(bridge_done),.error(bridge_error),.result(bridge_result),.read_line(bridge_read_line),
        .read_wait(bridge_read_wait),.write_wait(bridge_write_wait),
        .axi_addr(axi_addr),.arvalid(arvalid),.arready(arready),.rready(rready),
        .rvalid(rvalid),.rlast(rlast),.rdata(rdata),.rresp(rresp),
        .awvalid(awvalid),.awready(awready),.wvalid(wvalid),.wready(wready),
        .wdata(wdata),.wstrb(wstrb),.bready(bready),.bvalid(bvalid),.bresp(bresp)
    );
    wire [31:0] timer_data, uart_data, plic_data;
    wire timer_valid, uart_valid, plic_valid;
    wire mmio_fire=accept&&select_mmio;
    wire [31:0] perf_data;
    wire [15:0] perf_events={store_enq_fire,store_enq_req&&!store_enq_ready,
        bridge_write_wait,bridge_read_wait,d_tlb_miss_event,i_tlb_miss_event,
        d_miss_event,d_hit_event,i_miss_event,i_hit_event,fence_wait_event,
        muldiv_wait_event,data_wait_event,fetch_wait_event,retire_event,1'b1};
    fpga_perf_counters profiling (
        .clk(clk),.rst(cpu_rst),.enable(core_enable),
        .clear(mmio_fire&&select_perf&&select_we&&(select_addr[11:0]==0)),
        .events(perf_events),.addr(select_addr[11:0]),.rdata(perf_data)
    );
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
            transaction_addr_q<=0;transaction_data_q<=0;transaction_be_q<=0;
            transaction_we_q<=0;transaction_ram_q<=0;
        end else begin
            if(accept) begin
                owner<=select_owner; bad_address<=!select_ram&&!select_mmio;
                transaction_addr_q<=select_addr;transaction_data_q<=select_data;
                transaction_be_q<=select_be;transaction_we_q<=select_we;transaction_ram_q<=select_ram;
                state<=select_ram ? 1 : 2;
                mmio_result<=select_perf ? perf_data : (select_msip ? {31'b0,msip} :
                             (select_uart ? uart_data : (select_timer ? timer_data : plic_data)));
            end else if(complete) begin
                state<=0;
                // Queued instruction reads can be speculative. Their errors
                // travel with the instruction and trap precisely in CPU EX.
                if(bus_error&&!(FETCH_QUEUE&&owner==2)) fault_q<=1;
                if(owner==0&&!SERIAL_BOOT&&!bus_error) begin
                    boot_index<=boot_index+1;
                    if(boot_index==BOOT_WORDS-1) booted<=1;
                end
            end
            if(SERIAL_BOOT&&load_finish&&state==0&&calibrated&&!fault) booted<=1;
            if(ifatal||dfatal||store_queue_fault) fault_q<=1;
        end
    end
endmodule
