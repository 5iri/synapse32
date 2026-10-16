`timescale 1ns/1ps
`default_nettype none
module tb_fast_l1;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [1:0] req=0,we=0,translate=0,flush=0;
    reg [31:0] va[2],wdata[2],satp[2];
    reg [3:0] be[2];
    reg [2:0] kind[2];
    reg [1:0] privilege[2];
    wire [1:0] gnt,rvalid,fault,breq,bwe,bfetch,bgnt,bdone,fatal;
    wire [31:0] result[2],baddr[2],bdata[2];
    wire [3:0] bbe[2];
    reg [127:0] ram[0:4095];
    reg [127:0] response_line;
    reg [31:0] response_word,addr_q,data_q;
    reg [3:0] be_q;
    reg we_q=0,owner=0;
    reg [1:0] state=0;
    integer delay_q=0,reads=0,writes=0,cycle=0,n,lane;
    wire select_owner=breq[1];
    wire accepting=state==0&&(|breq);
    wire snoop=state==2&&we_q;
    assign bgnt[0]=accepting&&!select_owner;
    assign bgnt[1]=accepting&&select_owner;
    assign bdone[0]=(state==2)&&!owner;
    assign bdone[1]=(state==2)&&owner;
    genvar p;
    generate for(p=0;p<2;p=p+1) begin: ports
        sv32_bus_port #(.FETCH(p==0),.CACHE_LINES(4)) dut (
            .clk(clk),.rst(rst),.flush_tlb(flush[p]),
            .req(req[p]),.we(we[p]),.write_intent(we[p]),.translate(translate[p]),
            .va(va[p]),.satp(satp[p]),.wdata(wdata[p]),.privilege(privilege[p]),
            .sum(1'b0),.mxr(1'b0),.be(be[p]),.load_type(kind[p]),
            .gnt(gnt[p]),.rvalid(rvalid[p]),.page_fault(fault[p]),.rdata(result[p]),
            .bus_req(breq[p]),.bus_we(bwe[p]),.bus_fetch(bfetch[p]),
            .bus_addr(baddr[p]),.bus_wdata(bdata[p]),.bus_be(bbe[p]),
            .bus_gnt(bgnt[p]),.bus_done(bdone[p]),.bus_rdata(response_word),
            .bus_line(response_line),.bus_error(1'b0),.fatal_error(fatal[p]),
            .cache_hit_event(),.cache_miss_event(),.tlb_miss_event(),
            .snoop(snoop),.snoop_addr(addr_q),.snoop_data(data_q),.snoop_be(be_q),.snoop_error(1'b0)
        );
    end endgenerate
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin state<=0;delay_q<=0;end
        else case(state)
            0: if(accepting) begin
                owner<=select_owner;addr_q<=baddr[select_owner];data_q<=bdata[select_owner];
                be_q<=bbe[select_owner];we_q<=bwe[select_owner];delay_q<=8;state<=1;
            end
            1: if(delay_q>1) delay_q<=delay_q-1;
               else begin
                   response_line<=ram[addr_q[15:4]];
                   response_word<=32'(ram[addr_q[15:4]]>>(addr_q[3:0]*8));
                   if(we_q) begin
                       for(lane=0;lane<4;lane=lane+1)
                           if(be_q[lane]) ram[addr_q[15:4]][(int'(addr_q[3:0])+lane)*8+:8]<=data_q[lane*8+:8];
                       writes<=writes+1;
                   end else reads<=reads+1;
                   state<=2;
               end
            2: state<=0;
        endcase
    end
    task automatic access(input integer port,input bit wr,input [31:0] address,
                          input [31:0] data,input [3:0] strobes,input [2:0] load_kind,
                          input [31:0] expected,input integer expected_latency=-1,
                          input bit expected_fault=0);
        integer waited;
        begin
            @(negedge clk);req[port]=1;we[port]=wr;va[port]=address;wdata[port]=data;be[port]=strobes;kind[port]=load_kind;
            #1;
            while(!gnt[port]) @(negedge clk);
            @(negedge clk);req[port]=0;waited=1;
            while(!rvalid[port]&&waited<100) begin @(negedge clk);waited=waited+1;end
            if(!rvalid[port]||fault[port]!==expected_fault) $fatal(1,"response/fault at %h",address);
            if(!wr&&!expected_fault&&result[port]!==expected)
                $fatal(1,"read %h got %h expected %h",address,result[port],expected);
            if(expected_latency>=0&&waited!=expected_latency)
                $fatal(1,"hit at %h took %0d cycles expected %0d",address,waited,expected_latency);
            @(negedge clk);
        end
    endtask
    integer before_reads;
    initial begin
        for(n=0;n<4096;n=n+1) ram[n]={32'hffeeddcc,32'hbbaa9988,32'h77665544,32'h33221100};
        for(n=0;n<2;n=n+1) begin va[n]=32'h80000000;wdata[n]=0;satp[n]=0;be[n]=15;kind[n]=2;privilege[n]=3;end
        repeat(3) @(negedge clk);rst=0;
        access(0,0,32'h80000000,0,15,2,32'h33221100);
        before_reads=reads;
        access(0,0,32'h80000004,0,15,2,32'h77665544,1);
        access(1,0,32'h80000000,0,15,2,32'h33221100);
        access(1,0,32'h8000000b,0,15,0,32'hffffffbb,1);
        access(1,0,32'h8000000a,0,15,1,32'hffffbbaa,1);
        access(1,0,32'h8000000b,0,15,4,32'hbb,1);
        if(reads!=before_reads+1) $fatal(1,"full-line fill or independent bank allocation failed");
        // Resident hits on both ports complete together without shared-bus traffic.
        @(negedge clk);req=3;va[0]=32'h80000000;va[1]=32'h80000004;kind[1]=2;
        #1;
        if(gnt!==3) $fatal(1,"ports did not grant independently");
        @(negedge clk);req=0;
        if(rvalid!==3||result[0]!==32'h33221100||result[1]!==32'h77665544||breq!=0)
            $fatal(1,"simultaneous local hits failed");
        @(negedge clk);
        // A store by the data owner updates resident instructions and data by byte.
        access(1,1,32'h80000001,32'ha5,1,2,0);
        access(0,0,32'h80000000,0,15,2,32'h3322a500,1);
        access(1,0,32'h80000000,0,15,2,32'h3322a500,1);
        access(1,1,32'h8000000a,32'h1234,3,2,0);
        access(1,0,32'h80000008,0,15,2,32'h12349988,1);
        // I hit remains independent while the lower data store waits eight cycles.
        @(negedge clk);req[1]=1;we[1]=1;va[1]=32'h80000030;wdata[1]=32'hcafebabe;be[1]=15;
        #1;
        while(!gnt[1]) @(negedge clk);
        @(negedge clk);req[1]=0;
        repeat(2) @(negedge clk);
        req[0]=1;va[0]=32'h80000000;
        #1;
        @(negedge clk);req[0]=0;
        if(!rvalid[0]||result[0]!==32'h3322a500||rvalid[1]) $fatal(1,"I hit blocked behind data store");
        while(!rvalid[1]) @(negedge clk);
        @(negedge clk);we[1]=0;
        // Direct-map conflicts carry complete physical tags.
        access(0,0,32'h80000040,0,15,2,32'h33221100);
        before_reads=reads;
        access(0,0,32'h80000000,0,15,2,32'h3322a500);
        if(reads!=before_reads+1) $fatal(1,"physical tag conflict falsely hit");
        // Translate a user executable leaf, then check permissions on its TLB hit.
        // VPN[1]=0x100, so its root PTE is at 0x80001000 + 0x400.
        ram[320]=128'h00000000000000000000000020000801;
        ram[512]=128'h000000000000000000000000200000df;
        @(negedge clk);translate[0]=1;satp[0]=32'h80080001;privilege[0]=0;
        access(0,0,32'h40000000,0,15,2,32'h3322a500);
        access(0,0,32'h40000004,0,15,2,32'h77665544,1);
        @(negedge clk);privilege[0]=1;
        access(0,0,32'h40000004,0,15,2,0,1,1);
        // A changed fetch address must discard the accepted hit response.
        @(negedge clk);translate[0]=0;satp[0]=0;privilege[0]=3;
        repeat(2) @(negedge clk);
        req[0]=1;va[0]=32'h80000000;
        while(!gnt[0]) @(negedge clk);
        @(negedge clk);req[0]=0;va[0]=32'h80000004;
        #1;if(rvalid[0]) $fatal(1,"redirected cache hit escaped stale-fetch filtering");
        @(negedge clk);
        $display("PASS: independent one-cycle L1 hits, line fills, subwords, write snoops, tags, permissions, redirects");
        $finish;
    end
    initial begin #100000;$fatal(1,"global timeout");end
endmodule
