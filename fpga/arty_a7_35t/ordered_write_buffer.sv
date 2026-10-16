`default_nettype none
// Ordered, posted physical-RAM stores. The caller has already translated and
// checked permissions, and must snoop enq_fire into any resident I/D cache line.
// Loads that miss, page-table walks, MMIO, atomics and fences must wait until
// pending clears. Only one drain may be in flight; grant is not completion.
module ordered_write_buffer #(parameter integer DEPTH=4) (
    input wire clk, rst,
    input wire enq_req,
    input wire [31:0] enq_addr, enq_data,
    input wire [3:0] enq_be,
    output wire enq_ready, enq_fire, pending,
    output wire bus_req,
    output wire [31:0] bus_addr, bus_data,
    output wire [3:0] bus_be,
    input wire bus_gnt, bus_done, bus_error,
    output reg fault
);
    wire drain_fire;
    // Kept as named counters for simulation/ILA profiling. With no consumers,
    // synthesis may remove them. A stall counts a requested, unaccepted cycle.
    reg [63:0] enqueue_count, drain_count, stall_count;
    always @(posedge clk) begin
        if(rst) begin enqueue_count<=0; drain_count<=0; stall_count<=0; end
        else if(!fault) begin
            if(enq_fire) enqueue_count<=enqueue_count+1;
            if(drain_fire) drain_count<=drain_count+1;
            if(enq_req&&!enq_ready) stall_count<=stall_count+1;
        end
    end

    generate if(DEPTH>0) begin : posted
        localparam integer PTR_W=(DEPTH>1) ? $clog2(DEPTH) : 1;
        localparam integer COUNT_W=$clog2(DEPTH+1);
        reg [31:0] addr_q[0:DEPTH-1], data_q[0:DEPTH-1];
        reg [3:0] be_q[0:DEPTH-1];
        reg [PTR_W-1:0] head, tail;
        reg [COUNT_W-1:0] count;
        reg active;
        wire grant=bus_req&&bus_gnt;
        wire response=bus_done&&(active||grant);
        wire bad_response=bus_done&&(!(active||grant)||bus_error);

        // Conservatively hold full backpressure through the completion edge;
        // the vacated slot becomes ready in the following cycle.
        // Do not feed grant back into enqueue readiness: an arbiter may depend
        // on enq_fire when ordering reads behind new stores. Conservatively
        // block enqueue when a fresh grant completes in the very same cycle;
        // ordinary active-response enqueue/pop remains simultaneous.
        assign enq_ready=!rst&&!fault&&!(bus_done&&(!active||bus_error))&&
                         (count<COUNT_W'(DEPTH));
        assign enq_fire=enq_req&&enq_ready;
        assign pending=(count!=0);
        assign bus_req=!rst&&!fault&&!active&&(count!=0);
        assign bus_addr=addr_q[head];
        assign bus_data=data_q[head];
        assign bus_be=be_q[head];
        assign drain_fire=!rst&&!fault&&response&&!bus_error;

        always @(posedge clk) begin
            if(rst) begin head<=0; tail<=0; count<=0; active<=0; fault<=0; end
            else if(!fault) begin
                if(bad_response) fault<=1;
                else begin
                    if(grant) active<=1;
                    if(drain_fire) begin
                        active<=0;
                        head<=(head==PTR_W'(DEPTH-1)) ? 0 : head+1'b1;
                    end
                    if(enq_fire) begin
                        addr_q[tail]<=enq_addr; data_q[tail]<=enq_data; be_q[tail]<=enq_be;
                        tail<=(tail==PTR_W'(DEPTH-1)) ? 0 : tail+1'b1;
                    end
                    case({enq_fire,drain_fire})
                        2'b10: count<=count+1'b1;
                        2'b01: count<=count-1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end else begin : bypass
        // DEPTH=0 is non-posted: the source holds its request and metadata until
        // enq_fire acknowledges a successful physical completion. Metadata is
        // snapshotted on grant, and the downstream request is then suppressed.
        reg active;
        reg [31:0] addr_q, data_q;
        reg [3:0] be_q;
        wire grant=bus_req&&bus_gnt;
        wire response=bus_done&&(active||grant);
        wire bad_response=bus_done&&(!(active||grant)||bus_error);
        assign bus_req=enq_req&&!rst&&!fault&&!active;
        assign bus_addr=active ? addr_q : enq_addr;
        assign bus_data=active ? data_q : enq_data;
        assign bus_be=active ? be_q : enq_be;
        assign enq_ready=!rst&&!fault&&response&&!bus_error;
        assign enq_fire=enq_req&&enq_ready;
        assign pending=active||enq_req;
        assign drain_fire=!rst&&!fault&&response&&!bus_error;
        always @(posedge clk) begin
            if(rst) begin active<=0; fault<=0; addr_q<=0; data_q<=0; be_q<=0; end
            else if(!fault) begin
                if(bad_response) fault<=1;
                else begin
                    if(grant) begin
                        active<=1; addr_q<=enq_addr; data_q<=enq_data; be_q<=enq_be;
                    end
                    if(drain_fire) active<=0;
                end
            end
        end
    end endgenerate
endmodule
