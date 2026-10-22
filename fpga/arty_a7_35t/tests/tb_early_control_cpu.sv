`timescale 1ns/1ps
`default_nettype none
// Exercise selective control interlocks with real CPU instructions and public
// memory handshakes. RAM aliases high address bits to allow modulo-32 wrap tests.
module tb_early_control_cpu #(parameter LOAD_RESPONSE_FORMATTED=0, VARIABLE_LATENCY=1);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    localparam [31:0] BASE=32'h80000000,TRAP=BASE+32'hc00,STOP=BASE+32'he00,
                      SOURCE=32'h10000000,TARGET=32'h10000040,VALUE=32'h13579bdf;
    reg [31:0] rom[0:1023];
    reg [7:0] ram[0:4095];
    wire [31:0] pc,raddr,waddr,wdata;
    wire rd,wr;
    wire [3:0] be;
    wire [2:0] load_type;
    reg active=0,write_q=0,fault_enabled=0;
    reg [31:0] addr_q=0,data_q=0,watched=TARGET,consumer_pc=0;
    reg [3:0] be_q=0;
    reg [2:0] type_q=0;
    integer delay_q=0,transactions=0,target_reads=0,target_writes=0,hazards=0,held=0;
    wire done=active&&(delay_q==0);
    wire load_fault=done&&!write_q&&fault_enabled&&(addr_q==SOURCE);
    wire [31:0] raw={ram[addr_q[11:0]+3],ram[addr_q[11:0]+2],ram[addr_q[11:0]+1],ram[addr_q[11:0]]};
    reg [31:0] response;
    always @(*) begin
        response=raw;
        case(type_q)
            0:response=LOAD_RESPONSE_FORMATTED ? {{24{raw[7]}},raw[7:0]} : {24'h5a12ff,raw[7:0]};
            1:response=LOAD_RESPONSE_FORMATTED ? {{16{raw[15]}},raw[15:0]} : {16'h5a12,raw[15:0]};
            4:response=LOAD_RESPONSE_FORMATTED ? {24'b0,raw[7:0]} : {24'hfedcba,raw[7:0]};
            5:response=LOAD_RESPONSE_FORMATTED ? {16'b0,raw[15:0]} : {16'hfedc,raw[15:0]};
            default:response=raw;
        endcase
    end
    riscv_cpu #(.ITERATIVE_MULDIV(1),.FAST_MULTIPLY(1),.LOAD_FORWARDING(1),
                .LOAD_RESPONSE_FORMATTED(LOAD_RESPONSE_FORMATTED)) cpu (
        .clk(clk),.rst(rst),.module_instr_in((pc>=BASE&&pc<BASE+4096)?rom[pc[11:2]]:32'h13),
        .module_read_data_in(response),.module_pc_out(pc),.module_wr_data_out(wdata),
        .module_mem_wr_en(wr),.module_mem_rd_en(rd),.module_read_addr(raddr),.module_write_addr(waddr),
        .module_write_byte_enable(be),.module_load_type(load_type),
        .module_load_page_fault_in(load_fault),.module_store_page_fault_in(1'b0),
        .module_page_fault_addr_in(addr_q),.module_instr_page_fault_in(1'b0),
        .module_instr_access_fault_in(1'b0),.module_instr_gnt_in(1'b0),.module_instr_rvalid_in(1'b1),
        .module_data_gnt_in((rd||wr)&&!active),.module_data_rvalid_in(done&&!load_fault),
        .module_store_pending_in(1'b0),.timer_interrupt(1'b0),.software_interrupt(1'b0),.external_interrupt(1'b0));
    integer lane;
    always @(posedge clk) begin
        if(rst) begin
            active<=0;delay_q<=0;transactions<=0;target_reads<=0;target_writes<=0;hazards<=0;held<=0;
        end else begin
            if(cpu.if_id_pc_out==consumer_pc&&cpu.load_use_interlock&&cpu.hazard_stall&&!cpu.pipeline_hold)
                hazards<=hazards+1;
            if(cpu.id_ex_inst0_pc_out==consumer_pc&&cpu.mem_wait) held<=held+1;
            if(active) begin
                if(delay_q>0) delay_q<=delay_q-1;
                else begin
                    if(write_q)
                        for(lane=0;lane<4;lane=lane+1)
                            if(be_q[lane]) ram[addr_q[11:0]+lane]<=data_q[lane*8+:8];
                    active<=0;
                end
            end else if(rd||wr) begin
                addr_q<=wr?waddr:raddr;data_q<=wdata;be_q<=be;type_q<=load_type;write_q<=wr;
                // Delay the first producer too: every fresh case starts its
                // transaction counter at zero. Fixed mode covers no extra
                // delay; variable mode adds one through six waiting cycles.
                active<=1;delay_q<=VARIABLE_LATENCY ? 1+transactions%6 : 0;transactions<=transactions+1;
                if((wr?waddr:raddr)==watched) begin
                    if(wr) target_writes<=target_writes+1;else target_reads<=target_reads+1;
                end
            end
        end
    end
    function automatic [31:0] word_at(input [31:0] address);
        integer a;
        begin a=int'(address&32'hfff);word_at={ram[a+3],ram[a+2],ram[a+1],ram[a]};end
    endfunction
    task automatic put_word(input [31:0] address,input [31:0] value);
        integer a,n;
        begin a=int'(address&32'hfff);for(n=0;n<4;n=n+1) ram[a+n]=value[n*8+:8];end
    endtask
    function automatic [31:0] ins_i(input integer offset,input [4:0] rs,input [2:0] funct,input [4:0] dest,input [6:0] op);
        ins_i={offset[11:0],rs,funct,dest,op};
    endfunction
    function automatic [31:0] ins_s(input integer offset,input [4:0] rs,input [4:0] data_reg);
        ins_s={offset[11:5],data_reg,rs,3'b010,offset[4:0],7'h23};
    endfunction
    function automatic [31:0] ins_b(input integer offset,input [4:0] a,input [4:0] b,input [2:0] funct);
        ins_b={offset[12],offset[10:5],b,a,funct,offset[4:1],offset[11],7'h63};
    endfunction
    function automatic [31:0] ins_j(input integer offset,input [4:0] dest);
        ins_j={offset[20],offset[10:1],offset[11],offset[19:12],dest,7'h6f};
    endfunction
    function automatic [31:0] ins_csr(input [11:0] csr,input [4:0] source_reg);
        ins_csr={csr,source_reg,3'b001,5'b0,7'h73};
    endfunction
    integer cursor=0,cases=0;
    reg [31:0] producer_pc;
    task automatic emit(input [31:0] instruction);
        begin rom[cursor]=instruction;cursor=cursor+1;end
    endtask
    task automatic li(input [4:0] dest,input [31:0] value);
        reg [31:0] upper;
        begin upper=(value+32'h800)>>12;emit({upper[19:0],dest,7'h37});emit(ins_i(int'(value),dest,0,dest,7'h13));end
    endtask
    task automatic jump_stop;
        begin emit(ins_j(int'(STOP-(BASE+32'(cursor*4))),0));end
    endtask
    task automatic fresh;
        integer n;
        begin
            @(negedge clk);rst=1;
            repeat(3) @(negedge clk);
            for(n=0;n<1024;n=n+1) rom[n]=32'h13;
            for(n=0;n<4096;n=n+1) ram[n]=0;
            rom[768]=32'h0000006f;rom[896]=32'h0000006f;
            cursor=0;fault_enabled=0;watched=TARGET;consumer_pc=0;
            li(5,TRAP);emit(ins_csr(12'h305,5));
        end
    endtask
    task automatic trigger_setup(input integer slot,input integer kind,input [31:0] target,input bit enable);
        begin
            li(5,32'(slot));emit(ins_csr(12'h7a0,5));
            li(5,target);emit(ins_csr(12'h7a2,5));
            li(5,enable ? (32'h40|(32'b1<<kind)) : 0);emit(ins_csr(12'h7a1,5));
            emit({12'h300,5'd8,3'b110,5'b0,7'h73}); // csrrsi mstatus,8
        end
    endtask
    task automatic run_case(input string name,input integer cause,input [31:0] epc,input [31:0] trap_value);
        integer n;
        reg reached_trap,reached_stop;
        begin
            rst=0;
            for(n=0;n<2000&&pc!=STOP&&pc!=TRAP;n=n+1) @(negedge clk);
            reached_trap=pc==TRAP;reached_stop=pc==STOP;
            repeat(8) @(negedge clk);
            if(cause<0) begin
                if(!reached_stop) $fatal(1,"%s unexpectedly trapped cause=%0d epc=%h tval=%h pc=%h",name,cpu.csr_file_inst.mcause,cpu.csr_file_inst.mepc,cpu.csr_file_inst.mtval,pc);
            end else if(!reached_trap||cpu.csr_file_inst.mcause!=32'(cause)||
                        cpu.csr_file_inst.mepc!==epc||cpu.csr_file_inst.mtval!==trap_value)
                $fatal(1,"%s wrong trap cause=%0d epc=%h tval=%h pc=%h expected cause=%0d epc=%h tval=%h",name,cpu.csr_file_inst.mcause,cpu.csr_file_inst.mepc,cpu.csr_file_inst.mtval,pc,cause,epc,trap_value);
            cases=cases+1;
        end
    endtask
    task automatic dependent_watched(input integer slot,input bit store_access,input integer variant,input bit match_target);
        reg [31:0] target,base;
        integer offset;
        begin
            fresh();
            case(variant)
                0:begin target=TARGET;base=TARGET-32'h20;offset=32;end
                1:begin target=TARGET;base=TARGET+32'h20;offset=-32;end
                2:begin target=32'h10;base=32'hfffffff0;offset=32;end
                default:begin target=32'hfffffff0;base=32'h10;offset=-32;end
            endcase
            watched=target;trigger_setup(slot,store_access?1:0,target+(match_target?0:4),1);
            put_word(SOURCE,base);put_word(target,VALUE);
            li(6,SOURCE);li(7,32'h2468ace0);
            producer_pc=BASE+32'(cursor*4);emit(ins_i(0,6,2,5,7'h03));
            consumer_pc=BASE+32'(cursor*4);
            emit(store_access ? ins_s(offset,5,7) : ins_i(offset,5,2,10,7'h03));jump_stop();
            run_case("dependent watched access",match_target?3:-1,consumer_pc,target);
            if(hazards==0) $fatal(1,"watched address dependency did not interlock");
            if(match_target&&(target_reads!=0||target_writes!=0)) $fatal(1,"triggered access reached memory");
            if(!match_target) begin
                if(store_access&&word_at(target)!==32'h2468ace0) $fatal(1,"unwatched dependent store lost full operand");
                if(!store_access&&cpu.rf_inst0.register_file[10]!==VALUE) $fatal(1,"unwatched dependent load value");
            end
        end
    endtask
    reg [4:0] atomic_funct[0:10];
    function automatic [31:0] atomic_value(input integer operation,input [31:0] a,input [31:0] b);
        case(operation)
            2:atomic_value=b;3:atomic_value=a+b;4:atomic_value=a&b;5:atomic_value=a|b;6:atomic_value=a^b;
            7:atomic_value=$signed(a)>$signed(b)?a:b;8:atomic_value=$signed(a)<$signed(b)?a:b;
            9:atomic_value=a>b?a:b;default:atomic_value=a<b?a:b;
        endcase
    endfunction
    task automatic dependent_atomic(input integer slot,input integer operation,input bit matched);
        begin
            fresh();watched=TARGET;trigger_setup(slot,operation==1?1:0,TARGET+(matched?0:4),1);
            put_word(SOURCE,TARGET);put_word(TARGET,VALUE);li(6,SOURCE);li(7,17);
            emit(ins_i(0,6,2,5,7'h03));consumer_pc=BASE+32'(cursor*4);
            emit({atomic_funct[operation],2'b0,(operation==0?5'b0:5'd7),5'd5,3'b010,5'd10,7'h2f});jump_stop();
            run_case("dependent atomic address",matched?3:-1,consumer_pc,TARGET);
            if(hazards==0) $fatal(1,"atomic address dependency did not interlock");
            if(matched&&(target_reads||target_writes)) $fatal(1,"triggered atomic reached memory");
            if(!matched) begin
                if(cpu.rf_inst0.register_file[10]!== (operation==1?32'd1:VALUE)) $fatal(1,"atomic return value");
                if(word_at(TARGET)!==(operation<2?VALUE:atomic_value(operation,VALUE,17))) $fatal(1,"atomic memory value op%0d",operation);
            end
        end
    endtask
    task automatic csr_transition(input integer slot,input bit control_write,input bit store_access);
        begin
            fresh();trigger_setup(slot,store_access?1:0,TARGET+(control_write?0:4),!control_write);
            put_word(TARGET,VALUE);li(6,TARGET);li(7,17);
            li(5,control_write?(32'h40|(store_access?32'd2:32'd1)):TARGET);
            emit(ins_csr(control_write?12'h7a1:12'h7a2,5));
            consumer_pc=BASE+32'(cursor*4);emit(store_access?ins_s(0,6,7):ins_i(0,6,2,10,7'h03));jump_stop();
            run_case("trigger CSR transition flush",3,consumer_pc,TARGET);
            if(target_reads||target_writes) $fatal(1,"CSR transition left stale decoded access");
        end
    endtask
    task automatic branch_case(input bit taken,input bit rhs_dependency,input bit subword);
        begin
            fresh();put_word(SOURCE,subword?32'h80:32'd7);li(6,SOURCE);
            li(rhs_dependency?5'd10:5'd11,subword?32'hffffff80:(taken?32'd7:32'd8));
            emit(ins_i(0,6,subword?0:2,rhs_dependency?5'd11:5'd10,7'h03));
            consumer_pc=BASE+32'(cursor*4);emit(ins_b(8,10,11,0));
            emit(ins_i(85,0,0,12,7'h13));jump_stop();
            run_case("loaded branch",-1,0,0);
            if(hazards==0||cpu.rf_inst0.register_file[12]!==((taken||subword)?0:32'd85)) $fatal(1,"loaded branch decision/interlock");
        end
    endtask
    task automatic jalr_case(input bit misaligned);
        reg [31:0] target;
        begin
            fresh();target=BASE+32'ha00+(misaligned?2:0);put_word(SOURCE,target);li(6,SOURCE);
            emit(ins_i(0,6,2,5,7'h03));consumer_pc=BASE+32'(cursor*4);
            emit(ins_i(0,5,0,12,7'h67));emit(ins_i(1,0,0,11,7'h13));jump_stop();
            rom[640]=ins_i(119,0,0,11,7'h13);rom[641]=ins_j(int'(STOP-(BASE+32'ha04)),0);
            run_case("loaded JALR",misaligned?0:-1,consumer_pc,target);
            if(hazards==0) $fatal(1,"loaded JALR did not interlock");
            if(!misaligned&&(cpu.rf_inst0.register_file[11]!==119||cpu.rf_inst0.register_file[12]!==consumer_pc+4))
                $fatal(1,"loaded JALR target/link");
            if(misaligned&&cpu.rf_inst0.register_file[12]!=0) $fatal(1,"faulting JALR wrote its link");
        end
    endtask
    task automatic data_only_store;
        begin
            fresh();trigger_setup(2,1,TARGET+4,1);put_word(SOURCE,32'h80);li(6,SOURCE);li(7,TARGET);
            emit(ins_i(0,6,0,10,7'h03));consumer_pc=BASE+32'(cursor*4);emit(ins_s(0,7,10));jump_stop();
            run_case("store data only bypass",-1,0,0);
            if(hazards!=0||held==0||word_at(TARGET)!==32'hffffff80) $fatal(1,"store-data-only path interlocked or lost formatted operand");
        end
    endtask
    task automatic older_fault(input integer younger);
        begin
            fresh();fault_enabled=1;put_word(SOURCE,TRAP+32'h80);li(6,SOURCE);li(7,TARGET);
            producer_pc=BASE+32'(cursor*4);emit(ins_i(0,6,2,10,7'h03));
            consumer_pc=BASE+32'(cursor*4);
            case(younger)
                0:emit(ins_s(0,7,10));
                1:emit(ins_i(0,10,0,12,7'h67));
                default:emit(ins_b(8,10,0,0));
            endcase
            emit(ins_i(1,0,0,11,7'h13));jump_stop();
            run_case("older load fault",13,producer_pc,SOURCE);
            if(target_writes||cpu.rf_inst0.register_file[10]||cpu.rf_inst0.register_file[11]||cpu.rf_inst0.register_file[12])
                $fatal(1,"older fault permitted younger side effect");
        end
    endtask
    integer slot,kind,variant,match_target,operation;
    initial begin
        atomic_funct[0]=5'b00010;atomic_funct[1]=5'b00011;atomic_funct[2]=5'b00001;atomic_funct[3]=5'b00000;
        atomic_funct[4]=5'b01100;atomic_funct[5]=5'b01000;atomic_funct[6]=5'b00100;
        atomic_funct[7]=5'b10100;atomic_funct[8]=5'b10000;atomic_funct[9]=5'b11100;atomic_funct[10]=5'b11000;
        for(slot=0;slot<4;slot=slot+1) begin
            for(kind=0;kind<2;kind=kind+1)
                for(variant=0;variant<4;variant=variant+1)
                    for(match_target=0;match_target<2;match_target=match_target+1)
                        dependent_watched(slot,1'(kind),variant,1'(match_target));
            for(operation=0;operation<11;operation=operation+1)
                for(match_target=0;match_target<2;match_target=match_target+1)
                    dependent_atomic(slot,operation,1'(match_target));
            for(kind=0;kind<2;kind=kind+1) begin
                csr_transition(slot,0,1'(kind));csr_transition(slot,1,1'(kind));
            end
        end
        branch_case(0,0,0);branch_case(1,0,0);branch_case(0,1,0);branch_case(1,1,0);branch_case(1,0,1);
        jalr_case(0);jalr_case(1);data_only_store();
        older_fault(0);older_fault(1);older_fault(2);
        $display("PASS: early control CPU formatted=%0d variable_latency=%0d cases=%0d; all4 trigger slots/dependent +/- wrap accesses/all11 atomics/CSR transition flush/branch/JALR/data-only store/older faults",LOAD_RESPONSE_FORMATTED,VARIABLE_LATENCY,cases);
        $finish;
    end
    initial begin #20000000;$fatal(1,"global timeout");end
endmodule
