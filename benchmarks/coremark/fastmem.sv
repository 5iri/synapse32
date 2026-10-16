`default_nettype none
// A CPU-only experiment: independent fast instruction/data ports, no MMU/cache,
// bus bridge, DDR controller or operating system. Host RAM supplies the
// combinational backing store; mem_adapter defines every handshake/commit edge.
module fastmem #(
    parameter RESPONSE_LATENCY = 0
) (
    input wire clk, rst,
    input wire [31:0] instr_store_rdata, data_store_rdata,
    output wire [31:0] instr_store_addr, data_store_addr,
    output wire data_store_req, data_store_we,
    output wire [3:0] data_store_be,
    output wire [31:0] data_store_wdata,
    output wire data_write_fire, data_read_fire,
    output wire [2:0] data_load_type,
    output wire [31:0] pc,
    output wire [63:0] debug_cycles, debug_instret,
    output wire debug_fetch_wait, debug_mem_wait, debug_hazard_stall
);
    wire [31:0] instr, rdata, read_addr, write_addr, wdata;
    wire [3:0] be;
    wire wr_en, rd_en, instr_gnt, instr_valid, data_gnt, data_valid;
    mem_adapter #(.RESPONSE_LATENCY(RESPONSE_LATENCY)) instr_adapter (
        .clk(clk), .rst(rst), .req(!rst), .addr(pc), .we(1'b0),
        .be(4'b0), .wdata(32'b0), .gnt(instr_gnt), .rvalid(instr_valid),
        .rdata(instr), .store_req(), .store_addr(instr_store_addr),
        .store_we(), .store_be(), .store_wdata(), .write_fire(),
        .read_fire(), .store_rdata(instr_store_rdata)
    );
    mem_adapter #(.RESPONSE_LATENCY(RESPONSE_LATENCY)) data_adapter (
        .clk(clk), .rst(rst), .req(!rst && (rd_en || wr_en)),
        .addr(wr_en ? write_addr : read_addr), .we(wr_en), .be(be),
        .wdata(wdata), .gnt(data_gnt), .rvalid(data_valid), .rdata(rdata),
        .store_req(data_store_req), .store_addr(data_store_addr),
        .store_we(data_store_we), .store_be(data_store_be),
        .store_wdata(data_store_wdata), .write_fire(data_write_fire),
        .read_fire(data_read_fire), .store_rdata(data_store_rdata)
    );
`ifdef FASTMEM_ITERATIVE_CORE
    riscv_cpu #(.ITERATIVE_MULDIV(1)) cpu (
`else
    riscv_cpu cpu (
`endif
        .clk(clk), .rst(rst), .module_instr_in(instr),
        .module_read_data_in(rdata), .module_pc_out(pc),
        .module_wr_data_out(wdata), .module_mem_wr_en(wr_en),
        .module_mem_rd_en(rd_en), .module_read_addr(read_addr),
        .module_write_addr(write_addr), .module_write_byte_enable(be),
        .module_load_type(data_load_type),
        .module_load_page_fault_in(1'b0), .module_store_page_fault_in(1'b0),
        .module_page_fault_addr_in(32'b0), .module_instr_page_fault_in(1'b0),
        .module_instr_gnt_in(instr_gnt), .module_instr_rvalid_in(instr_valid),
        .module_data_gnt_in(data_gnt), .module_data_rvalid_in(data_valid),
        .module_data_write_intent_out(), .module_tlb_flush_out(),
        .module_data_mmu_enable_out(), .module_data_privilege_out(),
        .module_satp_out(), .module_data_sum_out(), .module_data_mxr_out(),
        .module_instr_mmu_enable_out(), .module_instr_privilege_out(),
        .timer_interrupt(1'b0), .software_interrupt(1'b0),
        .external_interrupt(1'b0)
    );
    assign debug_cycles = cpu.csr_file_inst.cycle_counter;
    assign debug_instret = cpu.csr_file_inst.instret_counter;
    assign debug_fetch_wait = cpu.fetch_wait;
    assign debug_mem_wait = cpu.mem_wait;
    assign debug_hazard_stall = cpu.hazard_stall;
endmodule
`default_nettype wire
