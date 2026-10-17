`timescale 1ns/1ps
`include "instr_defines.vh"
module tb_trigger_base_compare;
    reg [31:0] rs1=0,imm=0,mem_forward=0,wb_forward=0,pc=32'h80000080;
    reg [6:0] opcode=7'b0000011,instr_id=INSTR_LB;
    reg [1:0] forward_a=0;
    reg [3:0] enabled=0;
    reg [27:0] control=0;
    reg [127:0] targets=0;
    wire [31:0] address,tval,jump_address;
    wire breakpoint_hit,load_misaligned,store_misaligned,jump,execute_hit;
    integer count=0,load_hits=0,store_hits=0,execute_hits=0;
    reg [31:0] rng=32'h145a32e9;
    execution_unit #(.IMPLEMENT_M(0)) dut (
        .rs1(rs1),.rs2(32'b0),.imm(imm),.rs1_addr(5'd1),.rs2_addr(5'd2),
        .opcode(opcode),.instr_id(instr_id),.rs1_valid(1'b1),.rs2_valid(1'b1),
        .instr_valid(1'b1),.stage_enable(1'b1),.pc_input(pc),.instr(32'h13),
        .forward_a(forward_a),.forward_b(2'b0),.ex_mem_result(mem_forward),
        .mem_wb_result(wb_forward),.csr_read_data(32'b0),.csr_valid(1'b0),
        .interrupt_pending(1'b0),.interrupt_cause(32'b0),.interrupt_to_supervisor(1'b0),
        .interrupt_vector(32'b0),.mtvec(32'h80000100),.mepc(32'b0),
        .stvec(32'h80000200),.sepc(32'b0),.medeleg(32'b0),.privilege_mode(2'd3),
        .mstatus(32'b0),.mcounteren(32'b0),.scounteren(32'b0),
        .trigger_enabled(enabled),.trigger_control(control),.trigger_tdata2(targets),
        .mem_addr(address),.exception_tval(tval),.breakpoint_trigger_exception(breakpoint_hit),
        .load_address_misaligned_exception(load_misaligned),
        .store_address_misaligned_exception(store_misaligned),
        .jump_signal(jump),.jump_addr(jump_address),.execute_trigger_hit(execute_hit)
    );
    function automatic [31:0] random_word();
        rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
        random_word=rng;
    endfunction
    // The reference uses the original effective-address-plus-offset equality,
    // independently of the DUT's target-minus-offset implementation.
    function automatic reference_match(input [31:0] value,input integer kind);
        integer k;
        begin
            reference_match=0;
            for(k=0;k<4;k=k+1)
                reference_match|=enabled[k]&&control[7*k+kind]&&(value==targets[k*32+:32]);
        end
    endfunction
    function automatic [31:0] selected_base();
        case(forward_a)
            1:selected_base=mem_forward;
            2:selected_base=wb_forward;
            default:selected_base=rs1;
        endcase
    endfunction
    task automatic check();
        reg [31:0] expected_address,expected_tval;
        reg is_load,is_store,exec_match,data_match,mis_load,mis_store;
        begin
            expected_address=selected_base()+(opcode==7'b0101111 ? 32'b0 : imm);
            is_load=opcode==7'b0000011 || (opcode==7'b0101111 && instr_id!=INSTR_SC_W);
            is_store=opcode==7'b0100011 || (opcode==7'b0101111 && instr_id!=INSTR_LR_W);
            exec_match=reference_match(pc,2);
            data_match=(is_load&&reference_match(expected_address,0)) ||
                       (is_store&&reference_match(expected_address,1));
            mis_load=is_load&&((instr_id==INSTR_LH||instr_id==INSTR_LHU) ? expected_address[0] :
                     (instr_id==INSTR_LW||instr_id==INSTR_LR_W) ? |expected_address[1:0] : 1'b0);
            mis_store=is_store&&(instr_id==INSTR_SH ? expected_address[0] :
                      instr_id==INSTR_SB ? 1'b0 : |expected_address[1:0]);
            expected_tval=exec_match ? pc : (data_match||mis_load||mis_store) ? expected_address : 32'b0;
            #1;
            if(address!==(exec_match ? 32'b0 : expected_address) ||
               breakpoint_hit!==(exec_match||data_match) || execute_hit!==exec_match ||
               load_misaligned!==(!exec_match&&!data_match&&mis_load) ||
               store_misaligned!==(!exec_match&&!data_match&&mis_store) ||
               tval!==expected_tval || jump!==(exec_match||data_match||mis_load||mis_store))
                $fatal(1,"case%0d op=%h id=%h base=%h imm=%h wantaddr=%h gotaddr=%h hit=%b want=%b tval=%h want=%h",
                       count,opcode,instr_id,selected_base(),imm,expected_address,address,
                       breakpoint_hit,exec_match||data_match,tval,expected_tval);
            count=count+1;
            if(data_match&&is_load) load_hits=load_hits+1;
            if(data_match&&is_store) store_hits=store_hits+1;
            if(exec_match) execute_hits=execute_hits+1;
        end
    endtask
    integer slot,kind,n,mode,pick;
    reg [31:0] value,offset,effective;
    initial begin
        // Every trigger and access kind: positive wrap, negative immediate,
        // signed-immediate extremes, and MEM/WB/default operand selection.
        for(slot=0;slot<4;slot=slot+1) begin
            for(kind=0;kind<2;kind=kind+1) begin
                for(n=0;n<6;n=n+1) begin
                    case(n)
                        0:begin value=32'hfffffff0;offset=32'h20;end
                        1:begin value=32'h10;offset=32'hffffffe0;end
                        2:begin value=32'h7fffffff;offset=32'd1;end
                        3:begin value=32'h80000000;offset=32'hffffffff;end
                        4:begin value=32'h1000;offset=32'hfffff800;end
                        default:begin value=32'hfffff801;offset=32'd2047;end
                    endcase
                    for(mode=0;mode<4;mode=mode+1) begin
                        rs1=value;mem_forward=value;wb_forward=value;forward_a=2'(mode);imm=offset;
                        opcode=kind==0 ? 7'b0000011 : 7'b0100011;
                        instr_id=kind==0 ? INSTR_LB : INSTR_SB;
                        enabled=4'(1<<slot);control=0;control[7*slot+kind]=1;
                        targets=0;targets[slot*32+:32]=value+offset;
                        check();
                        enabled=0;check();enabled=4'(1<<slot);
                        control[7*slot+kind]=0;control[7*slot+1-kind]=1;check();
                        control=0;control[7*slot+kind]=1;
                        targets[slot*32+:32]=(value+offset)^32'h80000000;check();
                    end
                end
            end
            // Trigger priority over misalignment, and execute before data.
            rs1=32'h1001;mem_forward=rs1;wb_forward=rs1;forward_a=0;imm=0;
            opcode=7'b0000011;instr_id=INSTR_LW;control=0;
            control[7*slot]=1;targets=0;targets[slot*32+:32]=rs1;check();
            enabled=0;check();enabled=4'(1<<slot);
            control=0;control[7*slot+2]=1;targets[slot*32+:32]=pc;check();
            // Atomics retain zero-offset comparisons despite a nonzero imm.
            rs1=32'h12345000;imm=32'hfffff800;opcode=7'b0101111;
            for(n=0;n<3;n=n+1) begin
                instr_id=n==0 ? INSTR_LR_W : n==1 ? INSTR_SC_W : INSTR_AMOADD_W;
                control=0;control[7*slot+(n==1 ? 1 : 0)]=1;
                targets[slot*32+:32]=rs1;check();
                targets[slot*32+:32]=rs1+imm;check();
            end
        end
        for(n=0;n<10000;n=n+1) begin
            rs1=random_word();mem_forward=random_word();wb_forward=random_word();
            imm=random_word();value=random_word();forward_a=value[1:0];
            enabled=4'(random_word());control=28'(random_word());
            targets={random_word(),random_word(),random_word(),random_word()};
            kind=n%2;opcode=kind==0 ? 7'b0000011 : 7'b0100011;
            instr_id=kind==0 ? INSTR_LB : INSTR_SB;
            if(n%3!=0) begin
                pick=int'(value[3:2]);enabled[pick]=1;control[7*pick+kind]=1;
                targets[pick*32+:32]=selected_base()+imm;
            end
            check();
        end
        if(load_hits<100||store_hits<100||execute_hits<4) $fatal(1,"Vacuous trigger coverage");
        $display("PASS: trigger base comparison %0d cases; loadhits=%0d storehits=%0d exechits=%0d; all4 slots, wrap/negative offsets, disabled/wrong kind, forwarding and atomic/priority cases",count,load_hits,store_hits,execute_hits);
        $finish;
    end
endmodule
