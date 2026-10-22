`timescale 1ns/1ps
`include "instr_defines.vh"
module tb_atomic_trigger_forwarding;
    reg [31:0] rs1=32'hffffffe0,mem_value=32'h10,wb_value=32'h80001000,imm=0;
    reg [6:0] operation=INSTR_LR_W;
    reg [1:0] forwarding=0;
    reg [3:0] enabled=0;
    reg [27:0] control=0;
    reg [127:0] targets=0;
    reg active=1,valid=1,interrupt=0;
    localparam [31:0] PC=32'h80000080,VECTOR=32'h80000100;
    wire [31:0] address,tval,jump_address;
    wire hit,execute_hit,jump,flush,load_misaligned,store_misaligned,interrupt_taken;
    integer cases=0,hits=0;
    execution_unit #(.IMPLEMENT_M(0)) dut (
        .rs1(rs1),.rs2(32'b0),.imm(imm),.rs1_addr(5'd1),.rs2_addr(5'd2),
        .opcode(7'b0101111),.instr_id(operation),.rs1_valid(1'b1),.rs2_valid(1'b1),
        .instr_valid(valid),.stage_enable(active),.pc_input(PC),.instr(32'h13),
        .forward_a(forwarding),.forward_b(2'b0),.ex_mem_result(mem_value),.mem_wb_result(wb_value),
        .csr_read_data(32'b0),.csr_valid(1'b0),.interrupt_pending(interrupt),
        .interrupt_cause(32'h80000007),.interrupt_to_supervisor(1'b0),.interrupt_vector(VECTOR),
        .mtvec(VECTOR),.mepc(32'b0),.stvec(32'h80000200),.sepc(32'b0),.medeleg(32'b0),
        .privilege_mode(2'd3),.mstatus(32'b0),.mcounteren(32'b0),.scounteren(32'b0),
        .trigger_enabled(enabled),.trigger_control(control),.trigger_tdata2(targets),
        .mem_addr(address),.exception_tval(tval),.breakpoint_trigger_exception(hit),
        .load_address_misaligned_exception(load_misaligned),.store_address_misaligned_exception(store_misaligned),
        .jump_signal(jump),.jump_addr(jump_address),.flush_pipeline(flush),
        .interrupt_taken(interrupt_taken),.execute_trigger_hit(execute_hit)
    );
    function automatic [31:0] selected;
        case(forwarding)
            1:selected=mem_value;
            2:selected=wb_value;
            default:selected=rs1;
        endcase
    endfunction
    function automatic reference_match(input [31:0] value,input integer kind);
        integer k;
        begin
            reference_match=0;
            for(k=0;k<4;k=k+1)
                reference_match|=enabled[k]&&control[k*7+kind]&&(targets[k*32+:32]==value);
        end
    endfunction
    task automatic check;
        reg ex_match,data_match,mis_load,mis_store,want_hit,want_jump;
        reg [31:0] want_address,want_tval;
        begin
            ex_match=active&&valid&&reference_match(PC,2);
            data_match=valid&&((operation!=INSTR_SC_W&&reference_match(selected(),0))||
                              (operation!=INSTR_LR_W&&reference_match(selected(),1)));
            mis_load=(operation==INSTR_LR_W)&&((selected()&32'h3)!=0);
            mis_store=(operation!=INSTR_LR_W)&&((selected()&32'h3)!=0);
            want_hit=active&&!interrupt&&(ex_match||data_match);
            want_jump=active&&(interrupt||ex_match||data_match||mis_load||mis_store);
            want_address=(interrupt||ex_match) ? 32'b0 : selected();
            want_tval=interrupt ? 32'b0 : ex_match ? PC :
                      (data_match||mis_load||mis_store) ? selected() : 32'b0;
            #1;
            if(address!==want_address||hit!==want_hit||execute_hit!==ex_match||jump!==want_jump||
               flush!==want_jump||interrupt_taken!==(active&&interrupt)||
               load_misaligned!==(active&&!interrupt&&!ex_match&&!data_match&&mis_load)||
               store_misaligned!==(active&&!interrupt&&!ex_match&&!data_match&&mis_store)||
               (want_jump&&jump_address!==VECTOR)||(active&&tval!==want_tval))
                $fatal(1,"atomic trigger case%0d op=%h forwarding=%d base=%h imm=%h got addr=%h hit=%b execute=%b tval=%h jump=%b want addr=%h hit=%b execute=%b tval=%h jump=%b",
                       cases,operation,forwarding,selected(),imm,address,hit,execute_hit,tval,jump,
                       want_address,want_hit,ex_match,want_tval,want_jump);
            cases=cases+1;if(want_hit) hits=hits+1;
        end
    endtask
    integer slot,op,mode,kind,offset;
    initial begin
        // Distinct operand values ensure this checks actual MEM/WB selection,
        // rather than selecting identical values through every forwarding mux.
        for(slot=0;slot<4;slot=slot+1)
        for(op=0;op<11;op=op+1)
        for(mode=0;mode<4;mode=mode+1)
        for(kind=0;kind<3;kind=kind+1)
        for(offset=0;offset<4;offset=offset+1) begin
            operation=7'(INSTR_LR_W+op);forwarding=2'(mode);
            rs1=32'hffffffe0;mem_value=32'h10;wb_value=32'h80001000;
            case(offset)
                0:imm=32'h20;
                1:imm=32'hfffff800;
                2:imm=32'hffffffff;
                3:imm=32'h7fffffff;
            endcase
            enabled=4'(1<<slot);control=0;control[7*slot+kind]=1;targets=0;
            targets[slot*32+:32]=kind==2 ? PC : selected();check();
            // No atomic kind may match base+immediate. The immediate is a
            // deliberate poison even though its decoded value should be zero.
            targets[slot*32+:32]=selected()+imm;check();
            targets[slot*32+:32]=kind==2 ? PC : selected();
            enabled=0;check();enabled=4'(1<<slot);
            active=0;check();active=1;
            valid=0;check();valid=1;
        end
        // All atomic families: matching data triggers win over misalignment;
        // execute triggers win over data triggers, and interrupts win over both.
        for(slot=0;slot<4;slot=slot+1)
        for(op=0;op<11;op=op+1)
        for(mode=0;mode<3;mode=mode+1) begin
            operation=7'(INSTR_LR_W+op);forwarding=2'(mode);
            rs1=32'h1001;mem_value=32'h2001;wb_value=32'h3001;imm=32'hdeadbeef;
            enabled=4'(1<<slot);control=0;control[7*slot]=1;control[7*slot+1]=1;
            targets=0;targets[slot*32+:32]=selected();check();
            enabled=0;check();enabled=4'(1<<slot);
            control=0;control[7*slot+2]=1;targets[slot*32+:32]=PC;check();
            interrupt=1;check();interrupt=0;
        end
        if(hits<100) $fatal(1,"vacuous atomic trigger coverage");
        $display("PASS: atomic trigger forwarding %0d cases hits=%0d; all11 operations/all4 slots, distinct MEM/WB bases, ignored immediate, kinds/enable/hold/valid and misalignment/execute/interrupt priority",cases,hits);
        $finish;
    end
endmodule
