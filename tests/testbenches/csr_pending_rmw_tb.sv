`default_nettype none
module csr_pending_rmw_tb (
    input wire clk, rst,
    input wire [11:0] csr_addr,
    input wire [6:0] instr_id,
    input wire [31:0] rs1_value,
    input wire [4:0] rs1_addr,
    input wire read_enable, execute,
    input wire external_interrupt,
    output wire [31:0] rd_value,
    output wire [31:0] read_data
);
    wire [31:0] write_data;
    wire [31:0] write_mask;
    wire write_enable;
    csr_exec operation (
        .instr_id(instr_id), .rs1_value(rs1_value), .rs1_addr(rs1_addr),
        .csr_read_data(read_data), .csr_write_data(write_data),
        .csr_write_mask(write_mask),
        .csr_write_enable(write_enable), .rd_value(rd_value)
    );
    csr_file registers (
        .clk(clk), .rst(rst), .csr_addr(csr_addr), .write_data(write_data),
        .write_mask(write_mask),
        .write_enable(execute && write_enable), .read_enable(read_enable),
        .read_data(read_data), .csr_valid(),
        .interrupt_pending(1'b0), .interrupt_cause_in(32'b0), .interrupt_pc_in(32'b0),
        .exception_pc_in(32'b0), .interrupt_taken(1'b0), .mret_instruction(1'b0),
        .sret_instruction(1'b0), .interrupt_to_supervisor(1'b0), .trap_to_supervisor(1'b0),
        .ecall_exception(1'b0), .ebreak_exception(1'b0), .illegal_instruction_exception(1'b0),
        .instruction_address_misaligned_exception(1'b0), .load_address_misaligned_exception(1'b0),
        .store_address_misaligned_exception(1'b0), .instr_page_fault_exception(1'b0),
        .load_page_fault_exception(1'b0), .store_page_fault_exception(1'b0),
        .breakpoint_trigger_exception(1'b0), .exception_tval_in(32'b0), .instret_increment(1'b0),
        .trigger_control(), .trigger_tdata2(), .timer_interrupt(1'b0),
        .software_interrupt(1'b0), .external_interrupt(external_interrupt)
    );
endmodule
