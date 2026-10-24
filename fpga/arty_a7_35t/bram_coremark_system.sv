`default_nettype none
// Cache-free CPU with one true dual-port synchronous block RAM. The adapter
// supplies one-cycle handshakes; RAM output registers supply the read payload.
module bram_coremark_system #(
    parameter RAM_BYTES=131072, CLOCK_HZ=50000000,
    parameter MEM_FILE="coremark_bram.mem"
) (
    input wire clk, rst, uart_rx,
    output wire uart_tx,
    output reg fault=0, uart_seen=0,
    output wire [31:0] pc_debug
);
    localparam WORDS=RAM_BYTES/4, INDEX_BITS=$clog2(WORDS);
    localparam [31:0] BASE=32'h80000000, LIMIT=BASE+RAM_BYTES;
    (* ram_style="block" *) reg [31:0] ram [0:WORDS-1];
    initial $readmemh(MEM_FILE,ram);
    wire core_rst=rst||fault;
    wire [31:0] pc, raddr,waddr,wdata;
    wire [3:0] be;
    wire [2:0] load_type;
    wire wr,rd,ignt,ivalid,dgnt,dvalid;
    wire [31:0] ia,da,dw;
    wire [3:0] db;
    wire dreq,dwe,dfire,rfire,ifire;
    wire [31:0] mmio_response;
    reg [31:0] iq,dq;
    reg [1:0] offset_q;
    reg [2:0] type_q;
    reg ram_response_q;
    wire irange=(ia>=BASE)&&(ia<LIMIT)&&(ia[1:0]==0);
    wire [31:0] access_bytes=wr ? (be[3]?4:be[1]?2:1) :
        ((load_type==0||load_type==4)?1:(load_type==1||load_type==5)?2:4);
    wire drange=(da>=BASE)&&(da<LIMIT)&&(access_bytes<=LIMIT-da);
    wire uart_access=(da>=32'h20000000)&&(da<=32'h2000001c);
    wire timer_access=(da==32'h02004000)||(da==32'h02004004)||
                      (da==32'h0200bff8)||(da==32'h0200bffc);
    wire [3:0] shifted_be=db<<da[1:0];
    wire [31:0] shifted_data=dw<<(8*da[1:0]);
    // These clocked array reads infer the two BRAM ports, with no asynchronous
    // array output or reset mux. Port B writes one addressed byte per enable.
    always @(posedge clk) begin
        if(ifire&&irange) iq<=ram[ia[INDEX_BITS+1:2]];
        if(rfire&&drange) dq<=ram[da[INDEX_BITS+1:2]];
        if(dfire&&drange) begin
            for(integer lane=0;lane<4;lane=lane+1)
                if(shifted_be[lane]) ram[da[INDEX_BITS+1:2]][8*lane+:8]<=shifted_data[8*lane+:8];
        end
    end
    always @(posedge clk) begin
        if(dgnt) begin offset_q<=da[1:0]; type_q<=load_type; ram_response_q<=drange; end
    end
    wire [31:0] shifted_read=dq>>(8*offset_q);
    reg [31:0] formatted_read;
    always @* begin
        case(type_q)
            0: formatted_read={{24{shifted_read[7]}},shifted_read[7:0]};
            1: formatted_read={{16{shifted_read[15]}},shifted_read[15:0]};
            4: formatted_read={24'b0,shifted_read[7:0]};
            5: formatted_read={16'b0,shifted_read[15:0]};
            default: formatted_read=shifted_read;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin fault<=0;uart_seen<=0; end
        else if(!fault) begin
            if((ifire&&!irange)||(dreq&&dgnt&&!drange&&!uart_access&&!timer_access)) fault<=1;
            if(dfire&&uart_access) uart_seen<=1;
        end
    end
    mem_adapter #(.RESPONSE_LATENCY(1)) instruction_adapter (
        .clk(clk),.rst(core_rst),.req(!core_rst),.addr(pc),.we(1'b0),.be(4'b0),.wdata(32'b0),
        .gnt(ignt),.rvalid(ivalid),.rdata(),.store_req(),.store_addr(ia),.store_we(),
        .store_be(),.store_wdata(),.write_fire(),.read_fire(ifire),.store_rdata(32'b0)
    );
    wire [31:0] uart_data,timer_data;
    mem_adapter #(.RESPONSE_LATENCY(1)) data_adapter (
        .clk(clk),.rst(core_rst),.req(!core_rst&&(rd||wr)),.addr(wr?waddr:raddr),
        .we(wr),.be(be),.wdata(wdata),.gnt(dgnt),.rvalid(dvalid),.rdata(mmio_response),
        .store_req(dreq),.store_addr(da),.store_we(dwe),.store_be(db),.store_wdata(dw),
        .write_fire(dfire),.read_fire(rfire),
        .store_rdata(uart_access?uart_data:timer_access?timer_data:32'b0)
    );
    (* ASYNC_REG="TRUE" *) reg [1:0] rx_sync=2'b11;
    always @(posedge clk) rx_sync<={rx_sync[0],uart_rx};
    uart #(.DIVISOR_SCALE(16),.DEFAULT_DIVISOR((CLOCK_HZ+115200*8)/(115200*16))) console (
        .clk(clk),.rst(core_rst),.addr(da),.write_data(dw),
        .write_enable(dfire&&uart_access),.read_enable(rfire&&uart_access),
        .read_data(uart_data),.uart_valid(),.interrupt(),.tx(uart_tx),.rx(rx_sync[1]),.tx_idle()
    );
    wire timer_irq;
    timer clock_timer (.clk(clk),.rst(core_rst),.addr(da),.write_data(dw),
        .write_enable(dfire&&timer_access),.read_enable(rfire&&timer_access),
        .read_data(timer_data),.timer_valid(),.timer_interrupt(timer_irq));
    riscv_cpu #(.ITERATIVE_MULDIV(1)) cpu (
        .clk(clk),.rst(core_rst),.module_instr_in(iq),
        .module_read_data_in(ram_response_q?formatted_read:mmio_response),
        .module_pc_out(pc),.module_wr_data_out(wdata),.module_mem_wr_en(wr),
        .module_mem_rd_en(rd),.module_read_addr(raddr),.module_write_addr(waddr),
        .module_write_byte_enable(be),.module_load_type(load_type),
        .module_load_page_fault_in(1'b0),.module_store_page_fault_in(1'b0),
        .module_page_fault_addr_in(32'b0),.module_instr_page_fault_in(1'b0),
        .module_instr_gnt_in(ignt),.module_instr_rvalid_in(ivalid),
        .module_data_gnt_in(dgnt),.module_data_rvalid_in(dvalid),
        .module_data_write_intent_out(),.module_tlb_flush_out(),
        .module_data_mmu_enable_out(),.module_data_privilege_out(),.module_satp_out(),
        .module_data_sum_out(),.module_data_mxr_out(),.module_instr_mmu_enable_out(),
        .module_instr_privilege_out(),.timer_interrupt(timer_irq),
        .software_interrupt(1'b0),.external_interrupt(1'b0),
        .module_store_pending_in(1'b0),.module_data_atomic_out()
    );
    assign pc_debug=pc;
endmodule
