`default_nettype none
`include "memory_map.vh"
// Four responses/credits decouple the architectural PC from sequential fetch.
// The port has one in-flight lookup (or miss), with response and next grant
// allowed on the same cycle. No speculative fault is raised before CPU EX.
module instruction_fetch_queue (
    input wire clk, rst,
    input wire consume, redirect, flush_tlb,
    input wire [31:0] cpu_pc, redirect_pc,
    input wire translate,
    input wire [1:0] privilege,
    input wire [31:0] satp,
    output wire valid, page_fault, access_fault,
    output wire [31:0] instruction, head_pc,
    output wire req, cancel, port_cancel,
    output wire [31:0] request_pc,
    input wire gnt, rvalid, response_page_fault, response_access_fault,
    input wire [31:0] response_data
);
    reg [31:0] fetch_pc, pending_pc;
    reg pending, fault_stop;
    reg [2:0] count;
    reg [1:0] rd_ptr, wr_ptr;
    reg [31:0] words [0:3];
    reg [31:0] pcs [0:3];
    reg [3:0] page_faults, access_faults;
    reg translate_seen;
    reg [1:0] privilege_seen;
    reg [31:0] satp_seen;
    wire context_change=(translate!=translate_seen)||(privilege!=privilege_seen)||
                        (satp!=satp_seen);
    assign cancel=!rst&&(redirect||flush_tlb||context_change);
    reg cancel_q, redirect_q;
    reg [31:0] redirect_pc_q, cpu_pc_q;
    // Snapshot both possible PCs unconditionally. A live EX redirect may kill
    // CPU visibility, but must not enable a wide PC register or arbitrate the
    // cache port combinationally. The registered transaction owns that work.
    always @(posedge clk) begin
        cancel_q<=!rst&&cancel;
        redirect_q<=redirect;
        redirect_pc_q<=redirect_pc;
        cpu_pc_q<=cpu_pc;
    end
    assign port_cancel=cancel_q;
    wire [31:0] restart_pc=redirect_q ? redirect_pc_q : cpu_pc_q;
    wire stored_head=(count!=0);
    wire returned=rvalid&&pending&&!port_cancel;
    // Forward the first reply directly when empty: a redirect or miss does
    // not pay an extra FIFO clock. A stalled reply is retained in the queue.
    assign valid=!rst&&!cancel&&!port_cancel&&(stored_head||returned);
    assign instruction=stored_head ? words[rd_ptr] : response_data;
    assign head_pc=stored_head ? pcs[rd_ptr] : pending_pc;
    assign page_fault=valid&&(stored_head ? page_faults[rd_ptr] : response_page_fault);
    assign access_fault=valid&&(stored_head ? access_faults[rd_ptr] : response_access_fault);
    assign request_pc=port_cancel ? restart_pc : fetch_pc;
    // Every granted request reserves a slot until its response is consumed.
    // Conservative credits keep request timing independent of CPU backpressure.
    // Cancellation supplies a fresh credit and target. A port that can replace
    // a canceled local lookup may grant this new transaction on the same edge.
    assign req=!rst&&(port_cancel||(!fault_stop&&((count+{2'b0,pending})<4)));
    wire bypass=consume&&valid&&!stored_head;
    wire push=returned&&!bypass;
    wire pop=consume&&valid&&stored_head;
    always @(posedge clk) begin
        if(rst) begin
            fetch_pc<=`INSTR_MEM_BASE; pending_pc<=0; pending<=0;
            count<=0; rd_ptr<=0; wr_ptr<=0; fault_stop<=0;
            page_faults<=0; access_faults<=0;
            translate_seen<=0; privilege_seen<=3; satp_seen<=0;
        end else begin
            translate_seen<=translate; privilege_seen<=privilege; satp_seen<=satp;
            if(port_cancel) begin
                fetch_pc<=restart_pc+(gnt ? 32'd4 : 32'd0);
                pending_pc<=restart_pc;
                count<=0; rd_ptr<=0; wr_ptr<=0; pending<=gnt; fault_stop<=0;
            end else begin
                if(gnt) begin fetch_pc<=fetch_pc+4; pending_pc<=fetch_pc; end
                if(gnt||returned) pending<=gnt;
                if(returned&&(response_page_fault||response_access_fault)) fault_stop<=1;
                // Even a bypassed reply may write the unused tail slot. Only
                // its credit/pointer bookkeeping depends on CPU consumption;
                // the wide payload/PC storage has no late consumer enable.
                if(returned) begin
                    words[wr_ptr]<=response_data; pcs[wr_ptr]<=pending_pc;
                    page_faults[wr_ptr]<=response_page_fault;
                    access_faults[wr_ptr]<=response_access_fault;
                end
                if(push) wr_ptr<=wr_ptr+1'b1;
                if(pop) rd_ptr<=rd_ptr+1'b1;
                case({push,pop})
                    2'b10: count<=count+1'b1;
                    2'b01: count<=count-1'b1;
                    default: ;
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst&&!cancel&&!port_cancel) begin
        if(count+{2'b0,pending}>4) $fatal(1,"Fetch queue credit overflow");
        if(gnt&&pending&&!returned) $fatal(1,"Fetch port granted behind a pending miss");
        if(consume&&valid&&head_pc!=cpu_pc) $fatal(1,"Fetch queue PC differs from CPU PC");
    end
`endif
endmodule
