`timescale 1ns/1ps
`default_nettype none
module tb_instr_access_fault;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    localparam [31:0] BASE=32'h80000000, ENTRY=BASE+32'h80,
        MTRAP=BASE+32'h100, STRAP=BASE+32'h140;
    reg [31:0] rom[0:127];
    reg [31:0] fault_pc;
    reg page_case=0;
    wire [31:0] pc,wdata,raddr,waddr;
    wire wr,rd,dgnt,dvalid,write_fire,read_fire,consume,redirect,retire;
    wire [31:0] redirect_pc;
    wire [3:0] be;
    wire access_fault=!rst&&!page_case&&(pc==fault_pc);
    wire page_fault=!rst&&page_case&&(pc==fault_pc);
    wire [31:0] instruction=(pc>=BASE&&pc<BASE+512)?rom[pc[8:2]]:32'h00000013;
    wire [31:0] read_data;
    riscv_cpu #(.FETCH_QUEUE(1)) cpu (
        .clk(clk),.rst(rst),.module_instr_in(instruction),.module_read_data_in(read_data),
        .module_pc_out(pc),.module_wr_data_out(wdata),.module_mem_wr_en(wr),
        .module_mem_rd_en(rd),.module_read_addr(raddr),.module_write_addr(waddr),
        .module_write_byte_enable(be),.module_load_type(),
        .module_load_page_fault_in(1'b0),.module_store_page_fault_in(1'b0),
        .module_page_fault_addr_in(32'b0),.module_instr_page_fault_in(page_fault),
        .module_instr_access_fault_in(access_fault),.module_instr_gnt_in(1'b0),
        .module_instr_rvalid_in(1'b1),.module_data_gnt_in(dgnt),.module_data_rvalid_in(dvalid),
        .module_instr_consume_out(consume),.module_instr_redirect_out(redirect),
        .module_instr_redirect_pc_out(redirect_pc),.module_store_pending_in(1'b0),
        .module_data_atomic_out(),.module_retire_event_out(retire),
        .module_fetch_wait_out(),.module_data_wait_out(),.module_muldiv_wait_out(),
        .module_fence_wait_out(),.module_data_write_intent_out(),.module_tlb_flush_out(),
        .module_data_mmu_enable_out(),.module_data_privilege_out(),.module_satp_out(),
        .module_data_sum_out(),.module_data_mxr_out(),.module_instr_mmu_enable_out(),
        .module_instr_privilege_out(),.timer_interrupt(1'b0),.software_interrupt(1'b0),
        .external_interrupt(1'b0));
    mem_adapter #(.RESPONSE_LATENCY(8)) data_adapter (
        .clk(clk),.rst(rst),.req(!rst&&(wr||rd)),.addr(wr?waddr:raddr),
        .we(wr),.be(be),.wdata(wdata),.gnt(dgnt),.rvalid(dvalid),.rdata(read_data),
        .store_req(),.store_addr(),.store_we(),.store_be(),.store_wdata(),
        .write_fire(write_fire),.read_fire(read_fire),.store_rdata(32'b0));
    integer stores=0,wait_cycles=0,faults=0;
    reg [31:0] last_store=0;
    always @(posedge clk) begin
        if(rst) begin stores<=0;wait_cycles<=0;faults<=0;last_store<=0;end
        else begin
            if(write_fire) begin stores<=stores+1;last_store<=wdata;end
            if(cpu.mem_wait) begin
                wait_cycles<=wait_cycles+1;
                if(consume) $fatal(1,"Queue head consumed while MEM held the pipeline");
                if(cpu.instr_stage_fault_taken) $fatal(1,"Fetch fault overtook older memory");
            end
            if(redirect&&consume) $fatal(1,"Redirect consumed a stale queue head");
            if(cpu.instr_stage_fault_taken) begin
                faults<=faults+1;
                if(stores!=1) $fatal(1,"Instruction fault preceded older store completion");
                if(retire) $fatal(1,"Faulting instruction was counted as retired: page=%0d pc=%h",page_case,cpu.id_ex_inst0_pc_out);
            end
        end
    end
    function automatic [31:0] lui(input [4:0] rd,input [19:0] imm);
        lui={imm,rd,7'h37};
    endfunction
    function automatic [31:0] addi(input [4:0] rd,input [4:0] rs,input integer imm);
        addi={imm[11:0],rs,3'b000,rd,7'h13};
    endfunction
    function automatic [31:0] csrw(input [11:0] csr,input [4:0] rs);
        csrw={csr,rs,3'b001,5'b0,7'h73};
    endfunction
    function automatic [31:0] jump(input integer imm);
        jump={imm[20],imm[10:1],imm[11],imm[19:12],5'b0,7'h6f};
    endfunction
    task automatic run_case(input bit supervisor,input bit delegate,input bit wrong_path,input bit page);
        integer n;
        integer expected_cause;
        bit finished;
        begin
            @(negedge clk);rst=1;
            page_case=page;expected_cause=page?12:1;
            for(n=0;n<128;n=n+1) rom[n]=32'h00000013;
            rom[0]=lui(5,20'h80000);rom[1]=addi(5,5,32'h100);rom[2]=csrw(12'h305,5);
            rom[3]=addi(5,5,32'h40);rom[4]=csrw(12'h105,5);
            if(delegate&&page) begin rom[5]=lui(5,20'h1);end
            else rom[5]=addi(5,0,delegate?2:0);
            rom[6]=csrw(12'h302,5);
            if(supervisor) begin
                rom[7]=lui(5,20'h80000);rom[8]=addi(5,5,32'h80);rom[9]=csrw(12'h341,5);
                rom[10]=lui(5,20'h1);rom[11]=addi(5,5,-2048);rom[12]=csrw(12'h300,5);
                rom[13]=32'h30200073;
            end else rom[7]=jump(32'h80-7*4);
            if(wrong_path) begin
                rom[32]=jump(16);fault_pc=ENTRY+4;
                rom[33]=page?32'h00000013:32'h30200073; // Access-fault poison must not execute MRET.
                rom[36]=lui(6,20'h10000);rom[37]=addi(7,0,32'h66);
                rom[38]=32'h00732023;rom[39]=jump(0);
            end else begin
                rom[32]=lui(6,20'h10000);rom[33]=addi(7,0,32'h55);
                rom[34]=32'h00732023;fault_pc=ENTRY+12;
                rom[35]=page?32'h00000013:32'h30200073; // Page fault uses a NOP token.
            end
            rom[64]=jump(0);rom[80]=jump(0);
            repeat(5) @(negedge clk);rst=0;finished=0;
            for(n=0;n<350;n=n+1) begin
                @(negedge clk);
                if(wrong_path) begin
                    if(cpu.csr_file_inst.mcause!=0||cpu.csr_file_inst.scause!=0)
                        $fatal(1,"Wrong-path instruction fault was delivered: page=%0d",page);
                    if(stores==1&&last_store==32'h66&&n>80) finished=1;
                end else if(delegate ? cpu.csr_file_inst.scause==expected_cause : cpu.csr_file_inst.mcause==expected_cause) begin
                    if(delegate) begin
                        if(cpu.csr_file_inst.sepc!=fault_pc||cpu.csr_file_inst.stval!=fault_pc||
                           cpu.csr_file_inst.privilege_mode!=1||pc!=STRAP)
                            $fatal(1,"Delegated instruction fault lost PC/tval/vector/mode: page=%0d",page);
                    end else begin
                        if(cpu.csr_file_inst.mepc!=fault_pc||cpu.csr_file_inst.mtval!=fault_pc||
                           cpu.csr_file_inst.privilege_mode!=3||pc!=MTRAP)
                            $fatal(1,"Machine instruction fault lost PC/tval/vector/mode: page=%0d",page);
                    end
                    if(stores!=1||last_store!=32'h55||faults!=1||wait_cycles<8)
                        $fatal(1,"Instruction fault/store did not complete exactly once: page=%0d",page);
                    finished=1;
                end
                if(finished) break;
            end
            if(!finished) $fatal(1,"Timed out supervisor=%0d delegate=%0d wrongpath=%0d page=%0d",supervisor,delegate,wrong_path,page);
            $display("INSTR_FAULT_CASE_PASS supervisor=%0d delegate=%0d wrongpath=%0d page=%0d",supervisor,delegate,wrong_path,page);
        end
    endtask
    initial begin
        run_case(0,0,0,0);
        run_case(1,0,0,0);
        run_case(1,1,0,0);
        run_case(0,0,1,0);
        run_case(0,0,0,1);
        run_case(1,0,0,1);
        run_case(1,1,0,1);
        run_case(0,0,1,1);
        $display("INSTR_ACCESS_FAULT_PASS");$finish;
    end
endmodule
