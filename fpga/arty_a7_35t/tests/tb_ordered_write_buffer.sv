`timescale 1ns/1ps
`default_nettype none
module tb_ordered_write_buffer #(parameter DEPTH=4);
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg enq_req=0;
    reg [31:0] enq_addr=0, enq_data=0;
    reg [3:0] enq_be=0;
    wire enq_ready, enq_fire, pending, bus_req, fault;
    wire [31:0] bus_addr, bus_data;
    wire [3:0] bus_be;
    reg bus_gnt=0, bus_done=0, bus_error=0;
    ordered_write_buffer #(.DEPTH(DEPTH)) dut (.*);

    localparam BASE=32'h80000000;
    reg [31:0] expected_addr[0:255], expected_data[0:255];
    reg [3:0] expected_be[0:255];
    reg [7:0] expected_ram[0:255], actual_ram[0:255];
    reg [31:0] held_addr, held_data;
    reg [3:0] held_be;
    integer accepted=0, grants=0, commits=0, head=0, tail=0;
    integer i, lane, offset;
    reg in_flight=0;

    // The scoreboard observes the public handshakes only. Expected bytes are
    // updated in source order; actual bytes change only on successful response.
    always @(posedge clk) begin
        if(rst) begin
            accepted=0; grants=0; commits=0; head=0; tail=0; in_flight=0;
            for(i=0;i<256;i=i+1) begin expected_ram[i]=0; actual_ram[i]=0; end
        end else begin
            if((DEPTH>0 && enq_fire) || (DEPTH==0 && bus_req && bus_gnt)) begin
                expected_addr[tail]=enq_addr; expected_data[tail]=enq_data;
                expected_be[tail]=enq_be; tail=tail+1;
                offset=int'(enq_addr-BASE);
                for(lane=0;lane<4;lane=lane+1)
                    if(enq_be[lane]) expected_ram[offset+lane]=enq_data[8*lane+:8];
            end
            if(enq_fire) accepted=accepted+1;
            if(in_flight) begin
                if(bus_req) $fatal(1,"request repeated before response");
                if({bus_addr,bus_data,bus_be} !== {held_addr,held_data,held_be})
                    $fatal(1,"head changed after grant and before response");
            end
            if(bus_req && bus_gnt) begin
                if(in_flight || head>=tail) $fatal(1,"duplicate or unaccepted grant");
                if({bus_addr,bus_data,bus_be} !==
                   {expected_addr[head],expected_data[head],expected_be[head]})
                    $fatal(1,"drain was reordered or source snapshot was lost");
                held_addr=bus_addr; held_data=bus_data; held_be=bus_be;
                in_flight=1; grants=grants+1;
            end
            if(bus_done && in_flight && !bus_error && !fault) begin
                offset=int'(held_addr-BASE);
                for(lane=0;lane<4;lane=lane+1)
                    if(held_be[lane]) actual_ram[offset+lane]=held_data[8*lane+:8];
                in_flight=0; commits=commits+1; head=head+1;
            end
        end
    end

    task automatic tick;
        begin @(posedge clk); #1; @(negedge clk); end
    endtask
    task automatic reset_buffer;
        begin
            enq_req=0; bus_gnt=0; bus_done=0; bus_error=0; rst=1;
            tick(); tick(); rst=0; #1;
            if(pending || fault || bus_req || enq_fire) $fatal(1,"reset did not clear buffer");
        end
    endtask
    task automatic poison;
        begin enq_addr=BASE+128; enq_data=32'hbad0bad0; enq_be=0; end
    endtask
    task automatic enqueue(input [31:0] addr,input [31:0] data,input [3:0] be);
        begin
            if(!enq_ready) $fatal(1,"test tried enqueue while full");
            enq_req=1; enq_addr=addr; enq_data=data; enq_be=be;
            #1; if(!enq_fire) $fatal(1,"enqueue acceptance missing");
            tick(); enq_req=0; poison(); #1;
        end
    endtask
    task automatic grant_head(input integer delay_cycles);
        integer n;
        begin
            #1;
            if(!bus_req || !pending) $fatal(1,"queued head was not requested");
            bus_gnt=1; tick(); bus_gnt=0;
            for(n=0;n<delay_cycles;n=n+1) begin
                if(!pending || bus_req) $fatal(1,"grant incorrectly completed transaction");
                tick();
            end
        end
    endtask
    task automatic complete_head;
        begin bus_done=1; tick(); bus_done=0; #1; end
    endtask
    task automatic check_bytes;
        integer n;
        begin
            if(pending || in_flight || commits!=grants || head!=tail)
                $fatal(1,"not drained exactly once: grants=%0d commits=%0d",grants,commits);
            for(n=0;n<256;n=n+1)
                if(actual_ram[n]!==expected_ram[n])
                    $fatal(1,"ordered byte memory mismatch at %0d",n);
        end
    endtask
    task automatic nonposted_write(input [31:0] addr,input [31:0] data,input [3:0] be);
        begin
            enq_req=1; enq_addr=addr; enq_data=data; enq_be=be; #1;
            if(enq_ready || !bus_req || !pending) $fatal(1,"bypass acknowledged before response");
            tick(); tick();
            grant_head(3);
            if(enq_ready || enq_fire) $fatal(1,"bypass acknowledged on grant");
            bus_done=1; #1;
            if(!enq_ready || !enq_fire) $fatal(1,"bypass did not acknowledge completion");
            tick(); enq_req=0; bus_done=0; poison(); #1;
        end
    endtask

    integer n, before_accept, before_commit, before_grants, cycles, response_delay;
    initial begin
        @(negedge clk); reset_buffer();
        if(DEPTH>0) begin
            // A delayed bus cannot prevent a finite burst being accepted.
            for(n=0;n<DEPTH;n=n+1)
                enqueue(BASE,32'h44332211+n*32'h11111111,4'(1<<(n%4)));
            if(enq_ready || !pending) $fatal(1,"full queue did not backpressure");
            before_accept=accepted;
            enq_req=1; enq_addr=BASE+16; enq_data=32'h12345678; enq_be=15;
            tick(); tick();
            if(accepted!=before_accept) $fatal(1,"full queue accepted an extra store");
            grant_head(5);
            if(accepted!=before_accept) $fatal(1,"grant popped queue before response");
            complete_head(); enq_req=0; poison();
            if(accepted!=before_accept || !enq_ready)
                $fatal(1,"full queue must wait until completion before accepting again");
            while(pending) begin grant_head(2); complete_head(); end
            check_bytes();

            // A partially occupied queue may accept and retire together.
            if(DEPTH>1) begin
                enqueue(BASE+4,32'h12345678,15); grant_head(1);
                before_accept=accepted; before_commit=commits;
                enq_req=1; enq_addr=BASE+4; enq_data=32'haabbccdd; enq_be=5;
                bus_done=1; #1;
                if(!enq_fire) $fatal(1,"simultaneous enqueue/pop not accepted");
                tick(); enq_req=0; bus_done=0; poison(); #1;
                if(accepted!=before_accept+1 || commits!=before_commit+1 || !pending)
                    $fatal(1,"simultaneous enqueue/pop lost an entry");
                grant_head(0); complete_head(); check_bytes();
            end

            // Long deterministic stream wraps both pointers, mixes byte strobes,
            // and varies independent grant/response latency.
            before_accept=accepted; before_commit=commits; response_delay=0;
            for(cycles=0;cycles<1200 && commits<before_commit+40;cycles=cycles+1) begin
                enq_req=accepted<before_accept+40;
                enq_addr=BASE+32+4*((accepted-before_accept)%8);
                enq_data=32'h3182af05+32'(accepted-before_accept)*32'h01030709;
                enq_be=4'(1+((accepted-before_accept)*7)%15);
                bus_gnt=bus_req && (cycles%3==1);
                bus_done=in_flight && response_delay==0;
                if(bus_gnt) response_delay=1+(cycles%5);
                else if(in_flight && response_delay>0) response_delay=response_delay-1;
                tick();
            end
            enq_req=0; bus_gnt=0; bus_done=0; poison(); #1;
            if(cycles==1200 || accepted!=before_accept+40) $fatal(1,"stream did not drain");
            check_bytes();

            // A zero-latency target may grant and complete the head together.
            enqueue(BASE+80,32'h12345678,15);
            bus_gnt=1; bus_done=1; tick(); bus_gnt=0; bus_done=0; #1; check_bytes();

            // Reset discards queued and granted state.
            enqueue(BASE+84,32'h87654321,15); grant_head(2); reset_buffer();
            enqueue(BASE+88,32'h76543210,15); grant_head(1); complete_head(); check_bytes();

            // A failed response must prevent even a same-cycle new acceptance.
            enqueue(BASE+92,32'hffeeddcc,15); grant_head(2);
            before_accept=accepted; before_commit=commits; before_grants=grants;
            enq_req=1; enq_addr=BASE+96; enq_data=32'hfeedface; enq_be=15;
            bus_done=1; bus_error=1; #1;
            if(enq_fire || enq_ready) $fatal(1,"accepted store during fatal response");
            tick(); bus_done=0; bus_error=0;
            if(!fault || !pending || bus_req || enq_ready) $fatal(1,"failed response was not latched");
            tick(); tick();
            if(accepted!=before_accept || commits!=before_commit || grants!=before_grants)
                $fatal(1,"fatal error did not freeze queue");
            reset_buffer();
        end else begin
            nonposted_write(BASE,32'h44332211,15);
            nonposted_write(BASE,32'haabbccdd,5);
            nonposted_write(BASE+2,32'h00001234,3); check_bytes();
            // The bypass path supports a combinational completion, too.
            enq_req=1; enq_addr=BASE+8; enq_data=32'h11223344; enq_be=15;
            bus_gnt=1; bus_done=1; #1;
            if(!enq_fire) $fatal(1,"bypass immediate response was lost");
            tick(); enq_req=0; bus_gnt=0; bus_done=0; #1; check_bytes();
            enq_req=1; enq_addr=BASE+12; enq_data=32'habcd1234; enq_be=15;
            grant_head(1); reset_buffer();
            enq_req=1; enq_addr=BASE+16; enq_data=32'habcd1234; enq_be=15;
            grant_head(1); bus_done=1; bus_error=1; #1;
            if(enq_fire) $fatal(1,"bypass acknowledged failed write");
            tick(); bus_done=0; bus_error=0;
            if(!fault || bus_req || enq_ready) $fatal(1,"bypass did not halt after error");
            reset_buffer();
        end
        // A response without a granted write is a protocol fault.
        bus_done=1; tick(); bus_done=0;
        if(!fault || bus_req || enq_ready || pending) $fatal(1,"unexpected response did not halt buffer");
        tick(); if(!fault) $fatal(1,"fault was not sticky");
        reset_buffer();
        $display("PASS: ordered write buffer depth=%0d",DEPTH); $finish;
    end
    initial begin #1000000; $fatal(1,"global timeout"); end
endmodule
