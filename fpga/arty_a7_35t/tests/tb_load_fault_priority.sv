`timescale 1ns/1ps
`default_nettype none
// A delayed, faulting ordinary load is older than the instruction held in EX.
// Neither the dependent value nor an independent return/WFI may take effect.
module tb_load_fault_priority #(parameter LOAD_FORWARDING=1);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    localparam [31:0] BASE=32'h80000000, ENTRY=BASE+32'h80,
        TRAP=BASE+32'h100, POISON=BASE+32'h180;
    reg [31:0] rom[0:127];
    wire [31:0] pc,raddr,waddr,wdata;
    wire rd,wr,consume,redirect,retire;
    wire [31:0] redirect_pc;
    integer waited=0,stores=0,faults=0;
    wire load_fault=!rst&&rd&&(waited==6);
    riscv_cpu #(.LOAD_FORWARDING(LOAD_FORWARDING),.ITERATIVE_MULDIV(1)) cpu (
        .clk(clk),.rst(rst),
        .module_instr_in((pc>=BASE&&pc<BASE+512)?rom[pc[8:2]]:32'h00000013),
        .module_read_data_in(POISON),.module_pc_out(pc),
        .module_wr_data_out(wdata),.module_mem_wr_en(wr),.module_mem_rd_en(rd),
        .module_read_addr(raddr),.module_write_addr(waddr),.module_write_byte_enable(),
        .module_load_type(),.module_load_page_fault_in(load_fault),
        .module_store_page_fault_in(1'b0),.module_page_fault_addr_in(raddr),
        .module_instr_page_fault_in(1'b0),.module_instr_access_fault_in(1'b0),
        .module_instr_gnt_in(1'b0),.module_instr_rvalid_in(1'b1),
        .module_data_gnt_in(1'b0),.module_data_rvalid_in(1'b0),
        .module_store_pending_in(1'b0),.module_instr_consume_out(consume),
        .module_instr_redirect_out(redirect),.module_instr_redirect_pc_out(redirect_pc),
        .module_data_atomic_out(),.module_retire_event_out(retire),
        .module_fetch_wait_out(),.module_data_wait_out(),.module_muldiv_wait_out(),
        .module_fence_wait_out(),.module_data_write_intent_out(),.module_tlb_flush_out(),
        .module_data_mmu_enable_out(),.module_data_privilege_out(),.module_satp_out(),
        .module_data_sum_out(),.module_data_mxr_out(),.module_instr_mmu_enable_out(),
        .module_instr_privilege_out(),.timer_interrupt(1'b0),.software_interrupt(1'b0),
        .external_interrupt(1'b0));
    always @(posedge clk) begin
        if(rst) begin waited<=0;stores<=0;faults<=0;end
        else begin
            if(rd) waited<=waited+1;
            if(wr) stores<=stores+1;
            if(load_fault) begin
                faults<=faults+1;
                if(cpu.id_ex_inst0_pc_out!=ENTRY+4)
                    $fatal(1,"No younger EX instruction at older load fault");
                if(!redirect||redirect_pc!=TRAP||retire)
                    $fatal(1,"Load fault lost redirect/retirement priority");
            end
        end
    end
    function automatic [31:0] addi(input [4:0] rd,input [4:0] rs,input integer imm);
        addi={imm[11:0],rs,3'b000,rd,7'h13};
    endfunction
    function automatic [31:0] csrw(input [11:0] csr,input [4:0] rs);
        csrw={csr,rs,3'b001,5'b0,7'h73};
    endfunction
    task automatic run_case(input string name,input [31:0] younger);
        integer n;
        bit failed;
        begin
            @(negedge clk);rst=1;
            for(n=0;n<128;n=n+1) rom[n]=32'h00000013;
            rom[0]=32'h800002b7;rom[1]=addi(5,5,256);rom[2]=csrw(12'h305,5);
            rom[3]=addi(5,5,128);rom[4]=csrw(12'h341,5);
            rom[5]=32'h10000337;rom[6]=addi(7,0,32'h55);rom[7]=csrw(12'h340,7);
            rom[8]=32'h0600006f; // jal x0, ENTRY
            rom[32]=32'h00032503; // lw a0, 0(t1)
            rom[33]=younger;
            rom[34]=32'h0000006f;rom[64]=32'h0000006f;rom[96]=32'h0000006f;
            repeat(4) @(negedge clk);rst=0;
            for(n=0;n<100&&faults==0;n=n+1) @(negedge clk);
            if(faults!=1) $fatal(1,"No load fault for %s",name);
            repeat(4) @(negedge clk);
            failed=cpu.csr_file_inst.mcause!=13||cpu.csr_file_inst.mepc!=ENTRY||
                   cpu.csr_file_inst.mtval!=32'h10000000||
                   cpu.csr_file_inst.privilege_mode!=3||
                   cpu.csr_file_inst.mscratch!=32'h55||cpu.wfi_active||stores!=0||
                   cpu.rf_inst0.register_file[10]!=0||cpu.rf_inst0.register_file[11]!=0;
            if(failed) begin
                failures=failures+1;
                $display("LOAD_FAULT_PRIORITY_FAIL case=%s cause=%0d epc=%h tval=%h priv=%0d pc=%h mscratch=%h wfi=%0d stores=%0d",name,
                    cpu.csr_file_inst.mcause,cpu.csr_file_inst.mepc,cpu.csr_file_inst.mtval,
                    cpu.csr_file_inst.privilege_mode,pc,cpu.csr_file_inst.mscratch,cpu.wfi_active,stores);
            end else $display("LOAD_FAULT_PRIORITY_CASE_PASS case=%s",name);
        end
    endtask
    integer failures=0;
    initial begin
        run_case("dependent_alu",32'h00150593); // addi a1,a0,1
        run_case("dependent_store",32'h00a32223); // sw a0,4(t1)
        run_case("dependent_csr",32'h34051073); // csrw mscratch,a0
        run_case("dependent_jalr",32'h00050067); // jalr x0,0(a0)
        run_case("dependent_mul",32'h027505b3); // mul a1,a0,t2
        run_case("mret",32'h30200073);
        run_case("sret",32'h10200073);
        run_case("wfi",32'h10500073);
        if(failures) $fatal(1,"%0d load-fault priority cases failed",failures);
        $display("LOAD_FAULT_PRIORITY_PASS");$finish;
    end
endmodule
