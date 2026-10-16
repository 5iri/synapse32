`timescale 1ns/1ps
`default_nettype none
// Independent byte-strobed RAM, with split/stalled AXI write channels.
module tb_dcache #(parameter CACHE_LINES=256);
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg req=0, we=0, cache_read=1;
    reg [27:0] addr=0;
    reg [31:0] data=0;
    reg [3:0] be=15;
    wire ready,done,error;
    wire [31:0] result;
    wire [27:0] axi_addr;
    wire arvalid,rready,awvalid,wvalid,bready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg arready,awready,wready,rvalid=0,bvalid=0,rlast=1;
    reg [127:0] rdata=0;
    reg [1:0] rresp=0,bresp=0;
    reg inject_read_error=0,inject_write_error=0,inject_short=0;
    axi_word_bridge #(.CACHE_LINES(CACHE_LINES)) dut (.*);
    reg [127:0] ram[0:8191];
    reg [27:0] read_addr,write_addr;
    reg [127:0] write_data;
    reg [15:0] write_strobe;
    reg have_aw=0,have_w=0;
    integer ticks=0,read_delay=0,write_delay=0,reads=0,writes=0,i,n;
    always @(*) begin
        arready=!rvalid&&read_delay==0&&(ticks%3==1);
        awready=!have_aw&&!bvalid&&(ticks%5==1);
        wready=!have_w&&!bvalid&&(ticks%7==3);
    end
    always @(posedge clk) begin
        ticks<=ticks+1;
        if(arvalid&&arready) begin
            if(axi_addr[3:0]!=0) $fatal(1,"unaligned read");
            read_addr<=axi_addr; read_delay<=5; reads<=reads+1;
            rresp<=inject_read_error ? 2 : 0; rlast<=!inject_short;
        end else if(read_delay>1) read_delay<=read_delay-1;
        else if(read_delay==1) begin
            rdata<=ram[read_addr>>4];rvalid<=1;read_delay<=0;
        end
        if(rvalid&&rready) rvalid<=0;
        if(awvalid&&awready) begin write_addr<=axi_addr;have_aw<=1;end
        if(wvalid&&wready) begin write_data<=wdata;write_strobe<=wstrb;have_w<=1;end
        if(have_aw&&have_w&&write_delay==0&&!bvalid) begin
            bresp<=inject_write_error ? 2 : 0;
            if(!inject_write_error)
                for(i=0;i<16;i=i+1)
                    if(write_strobe[i]) ram[write_addr>>4][8*i+:8]<=write_data[8*i+:8];
            writes<=writes+1;write_delay<=4;
        end else if(write_delay>1) write_delay<=write_delay-1;
        else if(write_delay==1) begin bvalid<=1;write_delay<=0;end
        if(bvalid&&bready) begin bvalid<=0;have_aw<=0;have_w<=0;end
    end
    task automatic access(input bit wr,input bit cached,input [27:0] address,
                          input [31:0] value,input [3:0] strobes,
                          input [31:0] expected,input bit expected_error=0);
        integer timeout;
        begin
            @(negedge clk);
            while(!ready) @(negedge clk);
            req=1;we=wr;cache_read=cached;addr=address;data=value;be=strobes;
            @(negedge clk);req=0;
            // Poison live inputs: all cache and bus decisions must use the snapshot.
            addr=28'h1fff0;data=32'hbadbad;be=0;cache_read=!cached;we=!wr;
            timeout=0;
            while(!done&&timeout<200) begin @(negedge clk);timeout=timeout+1;end
            if(!done) $fatal(1,"transaction timeout at %h",address);
            if(error!==expected_error) $fatal(1,"error mismatch at %h",address);
            if(!wr&&!expected_error&&result!==expected)
                $fatal(1,"read %h got %h expected %h",address,result,expected);
            if(wr&&done&&(!ready)&&(have_aw||have_w||bvalid))
                $fatal(1,"write acknowledged before AXI response");
        end
    endtask
    localparam CONFLICT=(CACHE_LINES>0 ? CACHE_LINES : 1)*16;
    integer before_reads;
    reg [7:0] reference_ram[0:131071];
    reg [31:0] random_state=32'h193a27b5, random_data, expected_word;
    integer sample,random_addr,byte_count,word_byte;
    task automatic randomize_word;
        begin
            random_state=random_state^(random_state<<13);
            random_state=random_state^(random_state>>17);
            random_state=random_state^(random_state<<5);
        end
    endtask
    initial begin
        for(n=0;n<8192;n=n+1) ram[n]={32'hffeeddcc,32'hbbaa9988,32'h77665544,32'h33221100};
        repeat(3) @(negedge clk);rst=0;
        access(0,1,0,0,15,32'h33221100);
        before_reads=reads;
        access(0,1,4,0,15,32'h77665544);
        access(0,1,8,0,15,32'hbbaa9988);
        access(0,1,15,0,15,32'h000000ff);
        if(reads-before_reads!=(CACHE_LINES>0 ? 0 : 3)) $fatal(1,"line reuse did not avoid DDR reads");
        // Byte, halfword and sparse writes, including writes by uncached owners.
        access(1,0,1,32'h000000a5,1,0);
        access(1,1,10,32'h00001234,3,0);
        access(1,1,4,32'hdeadc0de,5,0);
        access(0,1,0,0,15,32'h3322a500);
        access(0,1,4,0,15,32'h77ad55de);
        access(0,1,8,0,15,32'h12349988);
        // Instruction/uncached reads always reach backing RAM and do not allocate.
        before_reads=reads;
        access(0,0,0,0,15,32'h3322a500);
        access(0,0,0,0,15,32'h3322a500);
        if(reads-before_reads!=2) $fatal(1,"uncached read used cache");
        access(0,0,16,0,15,32'h33221100);
        before_reads=reads;
        access(0,1,16,0,15,32'h33221100);
        if(reads-before_reads!=1) $fatal(1,"uncached read allocated");
        // Conflict replacement uses physical tags, not just index bits.
        access(0,1,CONFLICT,0,15,32'h33221100);
        before_reads=reads;
        access(0,1,0,0,15,32'h3322a500);
        if(reads-before_reads!=1) $fatal(1,"conflicting physical tag hit");
        // A store miss is write-through/no-write-allocate.
        access(1,1,CONFLICT,32'hcafef00d,15,0);
        before_reads=reads;
        access(0,1,CONFLICT,0,15,32'hcafef00d);
        if(reads-before_reads!=1) $fatal(1,"store miss allocated");
        // Failed writes invalidate a hit; failed fills must never become valid.
        inject_write_error=1;
        access(1,1,CONFLICT,32'hbadbad,15,0,1);
        inject_write_error=0;
        before_reads=reads;
        access(0,1,CONFLICT,0,15,32'hcafef00d);
        if(reads-before_reads!=1) $fatal(1,"failed write left a valid line");
        inject_read_error=1;
        access(0,1,32,0,15,0,1);
        inject_read_error=0;
        before_reads=reads;
        access(0,1,32,0,15,32'h33221100);
        if(reads-before_reads!=1) $fatal(1,"failed fill was cached");
        inject_short=1;
        access(0,1,48,0,15,0,1);
        inject_short=0;
        before_reads=reads;
        access(0,1,48,0,15,32'h33221100);
        if(reads-before_reads!=1) $fatal(1,"malformed fill was cached");
        // Reset invalidates cached data without resetting the RAM array.
        @(negedge clk);rst=1;
        repeat(2) @(negedge clk);rst=0;
        before_reads=reads;
        access(0,1,48,0,15,32'h33221100);
        if(reads-before_reads!=1) $fatal(1,"reset retained valid line");
        // Independent byte scoreboard across hits, misses and index conflicts.
        // Use a fixed seed so failures reproduce exactly on every simulator.
        for(n=0;n<131072;n=n+1) reference_ram[n]=ram[n/16][(n%16)*8+:8];
        for(sample=0;sample<300;sample=sample+1) begin
            randomize_word();random_addr=int'(random_state&32'h7ffc);
            randomize_word();random_data=random_state;
            if(random_state[0]) begin
                byte_count=1<<int'(random_state[2:1]%3);
                word_byte=(byte_count==4) ? 0 :
                          ((byte_count==2) ? (int'(random_state[3])*2) : int'(random_state[4:3]));
                random_addr=random_addr+word_byte;
                access(1,random_state[5],28'(random_addr),random_data,4'((1<<byte_count)-1),0);
                for(n=0;n<byte_count;n=n+1) reference_ram[random_addr+n]=random_data[n*8+:8];
            end
            random_addr=random_addr&~3;
            expected_word={reference_ram[random_addr+3],reference_ram[random_addr+2],
                           reference_ram[random_addr+1],reference_ram[random_addr]};
            access(0,1,28'(random_addr),0,15,expected_word);
            access(0,1,28'(random_addr),0,15,expected_word);
        end
        $display("PASS: D-cache lines=%0d reads=%0d writes=%0d",CACHE_LINES,reads,writes);
        $finish;
    end
    initial begin #1000000;$fatal(1,"global timeout");end
endmodule
