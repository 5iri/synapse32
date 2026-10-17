`timescale 1ns/1ps
`default_nettype none
// Reuse the SoC forwarding program against the CPU's two response contracts.
// Raw subword responses deliberately contain unrelated upper bits.
module tb_load_response_contract #(parameter LOAD_RESPONSE_FORMATTED=0);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [31:0] rom[0:255];
    reg [7:0] ram[0:8191];
    wire [31:0] pc,raddr,waddr,wdata;
    wire [3:0] be;
    wire [2:0] kind;
    wire rd,wr;
    reg active=0,write_q=0;
    reg [31:0] addr_q=0,data_q=0;
    reg [3:0] be_q=0;
    reg [2:0] kind_q=0;
    integer delay_q=0,transactions=0,loads=0,stores=0,n,lane;
    reg [4:0] kinds_seen=0;
    wire done=active&&(delay_q==0);
    wire [31:0] raw_word={ram[addr_q[12:0]+3],ram[addr_q[12:0]+2],
                          ram[addr_q[12:0]+1],ram[addr_q[12:0]]};
    reg [31:0] response;
    always @(*) begin
        response=raw_word;
        case(kind_q)
            0: response=LOAD_RESPONSE_FORMATTED ? {{24{raw_word[7]}},raw_word[7:0]} :
                                                  {24'h5a12ff,raw_word[7:0]};
            1: response=LOAD_RESPONSE_FORMATTED ? {{16{raw_word[15]}},raw_word[15:0]} :
                                                  {16'h1234,raw_word[15:0]};
            4: response=LOAD_RESPONSE_FORMATTED ? {24'b0,raw_word[7:0]} :
                                                  {24'hfedcba,raw_word[7:0]};
            5: response=LOAD_RESPONSE_FORMATTED ? {16'b0,raw_word[15:0]} :
                                                  {16'hfedc,raw_word[15:0]};
            default: response=raw_word;
        endcase
    end
    riscv_cpu #(.ITERATIVE_MULDIV(1),.FAST_MULTIPLY(1),.LOAD_FORWARDING(1),
                .LOAD_RESPONSE_FORMATTED(LOAD_RESPONSE_FORMATTED)) cpu (
        .clk(clk),.rst(rst),.module_instr_in(rom[pc[9:2]]),.module_read_data_in(response),
        .module_pc_out(pc),.module_wr_data_out(wdata),.module_mem_wr_en(wr),.module_mem_rd_en(rd),
        .module_read_addr(raddr),.module_write_addr(waddr),.module_write_byte_enable(be),
        .module_load_type(kind),.module_load_page_fault_in(1'b0),.module_store_page_fault_in(1'b0),
        .module_page_fault_addr_in(32'b0),.module_instr_page_fault_in(1'b0),
        .module_instr_access_fault_in(1'b0),.module_instr_gnt_in(1'b0),.module_instr_rvalid_in(1'b1),
        .module_data_gnt_in((rd||wr)&&!active),.module_data_rvalid_in(done),
        .module_store_pending_in(1'b0),.timer_interrupt(1'b0),.software_interrupt(1'b0),
        .external_interrupt(1'b0));
    function automatic [31:0] word_at(input integer address);
        word_at={ram[address+3],ram[address+2],ram[address+1],ram[address]};
    endfunction
    always @(posedge clk) begin
        if(!rst) begin
            if(active) begin
                if(delay_q>0) delay_q<=delay_q-1;
                else begin
                    if(write_q) begin
                        for(lane=0;lane<4;lane=lane+1)
                            if(be_q[lane]) ram[addr_q[12:0]+lane]<=data_q[lane*8+:8];
                        stores<=stores+1;
                    end else begin
                        case(kind_q)
                            0:kinds_seen[0]<=1; 1:kinds_seen[1]<=1; 2:kinds_seen[2]<=1;
                            4:kinds_seen[3]<=1; 5:kinds_seen[4]<=1;
                            default:$fatal(1,"unexpected load kind %0d",kind_q);
                        endcase
                        loads<=loads+1;
                    end
                    active<=0;
                end
            end else if(rd||wr) begin
                if((wr?waddr:raddr)<32'h10000000||(wr?waddr:raddr)>=32'h10001ffc)
                    $fatal(1,"unexpected data address %h",wr?waddr:raddr);
                addr_q<=wr?waddr:raddr;data_q<=wdata;be_q<=be;kind_q<=kind;
                write_q<=wr;active<=1;delay_q<=1+transactions%4;transactions<=transactions+1;
            end
            if(word_at('h304)==32'h600d) begin
                if(word_at('h300)!=32'h10000000||kinds_seen!=5'b11111||
                   word_at('h420)!=32'hffffff81||word_at('h424)!=32'h00000081||
                   word_at('h428)!=32'hffff8002||word_at('h42c)!=32'h00008002||
                   word_at('h430)!=32'h8001ff80||word_at('h434)!=32'h00001237||
                   word_at('h438)!=32'h55||word_at('h43c)!=32'h014b5a90)
                    $fatal(1,"load response contract failed formatted=%0d kinds=%b",
                           LOAD_RESPONSE_FORMATTED,kinds_seen);
                $display("LOAD_RESPONSE_CONTRACT_PASS formatted=%0d loads=%0d stores=%0d",
                         LOAD_RESPONSE_FORMATTED,loads,stores);
                $finish;
            end
        end
    end
    initial begin
        for(n=0;n<8192;n=n+1) ram[n]=0;
        $readmemh("build/load-forwarding.hex",rom);
        repeat(5) @(negedge clk);rst=0;
        repeat(20000) @(negedge clk);
        $fatal(1,"contract timeout formatted=%0d pc=%h",LOAD_RESPONSE_FORMATTED,pc);
    end
endmodule
