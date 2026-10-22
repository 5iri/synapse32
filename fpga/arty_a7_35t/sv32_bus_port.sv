`default_nettype none
`include "memory_map.vh"
// DDR-facing Sv32 front end, using the unmodified upstream leaf-PTE TLB.
// Each port has eight entries; permissions are checked again on every hit.
// Snapshot each access and return one response. Svade: A/D clear faults.
module sv32_bus_port #(parameter FETCH=0, CACHE_LINES=0, PIPELINED_FETCH=0,
                      EARLY_STORE_RESPONSE=0, RESTART_ON_CANCEL=0) (
    input wire clk, rst, flush_tlb,
    input wire fetch_cancel,
    input wire req, we, write_intent, translate,
    input wire [31:0] va, satp, wdata,
    input wire [1:0] privilege,
    input wire sum, mxr,
    input wire [3:0] be,
    input wire [2:0] load_type,
    output wire gnt, rvalid, page_fault, access_fault,
    output wire [31:0] rdata,
    output wire bus_req,
    output wire bus_we,
    output wire bus_fetch,
    output reg [31:0] bus_addr,
    output wire [31:0] bus_wdata,
    output wire [3:0] bus_be,
    input wire bus_gnt, bus_done,
    input wire [31:0] bus_rdata,
    input wire [127:0] bus_line,
    input wire bus_error,
    input wire snoop,
    input wire [31:0] snoop_addr, snoop_data,
    input wire [3:0] snoop_be,
    input wire snoop_error,
    output wire cache_hit_event, cache_miss_event, tlb_miss_event,
    output reg fatal_error
);
    localparam IDLE=0, PTE_REQ=1, PTE_WAIT=2, ACCESS_REQ=3, ACCESS_WAIT=4, DONE=5,
               CACHE_LOOKUP=6, CACHE_REQUEST=7;
    localparam PIPE_FETCH=FETCH&&PIPELINED_FETCH;
    reg [2:0] state;
    reg [31:0] va_q, satp_q, data_q;
    reg [1:0] privilege_q;
    reg translate_q, we_q, intent_q, sum_q, mxr_q, level, fault_q, access_fault_q;
    reg [3:0] be_q;
    reg [2:0] type_q;
    reg [31:0] satp_seen;
    reg [31:0] response_q;
    // Hierarchical performance counters; they do not alter the CPU interface.
    reg [63:0] cache_hits, cache_misses, store_wait_cycles;
    reg walk_discard;
    // The upstream TLB has no address-space tags. Flush on every satp change,
    // including ASID-only changes, in addition to the CPU's fence/write pulse.
    wire invalidate=flush_tlb||(satp!=satp_seen);
    wire ram_pte=`IS_INSTR_MEM(bus_addr)||`IS_DATA_MEM(bus_addr);
    wire context_changed=(satp_q!=satp)||(translate_q!=translate)||(privilege_q!=privilege);
    // A queued frontend owns request-PC tags. Its next request VA may advance
    // while the previous hit returns, and redirects are canceled explicitly.
    wire stale=FETCH && (walk_discard||invalidate||(PIPE_FETCH ? fetch_cancel : (va_q!=va))||(satp_q!=satp)||
                       (translate_q!=translate)||(privilege_q!=privilege));
    // The queued frontend supplies a registered cancellation together with a
    // separately tagged new target. Replace a local transaction immediately,
    // but retain ownership of any granted lower read until its response drains.
    wire lower_pending=((state==PTE_WAIT)||(state==ACCESS_WAIT))&&!bus_done;
    wire lower_granted=((state==PTE_REQ)||(state==ACCESS_REQ))&&bus_req&&bus_gnt;
    wire restart_slot=PIPE_FETCH&&RESTART_ON_CANCEL&&fetch_cancel&&!lower_pending&&!lower_granted;
    wire restart_gnt=req&&!fatal_error&&!invalidate&&restart_slot;
    // The bridge has already registered a completed lower read. Return its
    // instruction token directly and start the next lookup on that same edge.
    // Concurrent cache fill/lookup forwarding covers the same-line successor.
    // Errors return exactly one fault token and leave the next request ungranted.
    wire fetch_complete=PIPE_FETCH&&(state==ACCESS_WAIT)&&bus_done&&!stale;
    wire fetch_next_slot=fetch_complete&&!bus_error;
    assign gnt=req&&!fatal_error&&!invalidate&&
               (restart_slot||(!(PIPE_FETCH&&fetch_cancel)&&
                ((state==IDLE)||(PIPE_FETCH&&(state==CACHE_LOOKUP)&&cache_hit&&!stale)||fetch_next_slot)));
    // A write has no response data to register. Once its actual completion is
    // visible, acknowledge it directly and avoid a separate DONE cycle. This
    // never acknowledges a grant, a permission fault, or a failed transaction.
    wire early_store_response=EARLY_STORE_RESPONSE&&!FETCH&&we_q&&
                              (state==ACCESS_WAIT)&&bus_done&&!bus_error;
    assign rvalid=((state==DONE)||((state==CACHE_LOOKUP)&&cache_hit)||
                   early_store_response||fetch_complete)&&!stale;
    assign page_fault=rvalid&&fault_q;
    assign access_fault=PIPE_FETCH&&rvalid&&(fetch_complete ? bus_error : access_fault_q);
    // Lower-bus arbitration must not depend on the EX-stage redirect path.
    // RESTART_ON_CANCEL receives the queue's registered cancellation. Stop an
    // ungranted old read before arbitration so a redirect need not drain an
    // unnecessary DDR access. An earlier grant is already in WAIT and retains
    // ownership below. Legacy ports with live EX cancellation still allow the
    // same-edge grant and drain it without a CPU response.
    assign bus_req=(((state==PTE_REQ)&&ram_pte)||
                    ((state==ACCESS_REQ)&&(!PIPE_FETCH||ram_pte)))&&
                   !(PIPE_FETCH&&(walk_discard||(RESTART_ON_CANCEL&&fetch_cancel)));
    assign bus_we=(state==ACCESS_REQ)&&we_q;
    assign bus_fetch=FETCH&&(state==ACCESS_REQ);
    assign bus_wdata=data_q;
    assign bus_be=(state==ACCESS_REQ) ? be_q : 4'b1111;
    wire pte_valid=bus_rdata[0] && !(bus_rdata[2]&&!bus_rdata[1]) &&
                   (bus_rdata[31:30]==0);
    wire leaf=bus_rdata[1]||bus_rdata[3];
    wire [31:0] leaf_physical=level ? {bus_rdata[29:20],va_q[21:0]} :
                                                    {bus_rdata[29:10],va_q[11:0]};
    function automatic permitted;
        input [31:0] pte;
        input [1:0] priv;
        input intent, sum_bit, mxr_bit;
        begin
            permitted=(priv==0 ? pte[4] : (!pte[4]||(!FETCH&&sum_bit))) &&
                      pte[6] && (FETCH ? pte[3] :
                      (intent ? (pte[2]&&pte[7]) : (pte[1]||(mxr_bit&&pte[3]))));
        end
    endfunction
    wire permission_ok=permitted(bus_rdata,privilege_q,intent_q,sum_q,mxr_q);
    wire tlb_hit, tlb_megapage;
    wire [31:0] tlb_pte;
    wire hit_permitted=permitted(tlb_pte,privilege,write_intent,sum,mxr);
    assign cache_hit_event=(state==CACHE_LOOKUP)&&cache_hit&&!stale;
    assign cache_miss_event=(state==CACHE_LOOKUP)&&!cache_hit&&!stale;
    assign tlb_miss_event=gnt&&translate&&(satp[21:20]==0)&&!tlb_hit;
    wire fast_translation=!translate||((satp[21:20]==0)&&tlb_hit&&hit_permitted);
    wire [31:0] hit_physical=!translate ? va : (tlb_megapage ?
                                             {tlb_pte[29:20],va[21:0]} :
                                             {tlb_pte[29:10],va[11:0]});
    wire direct_cache=(CACHE_LINES>0)&&!we&&fast_translation&&
                      (`IS_INSTR_MEM(hit_physical)||`IS_DATA_MEM(hit_physical));
    // A speculative BRAM read has no architectural side effects. On the
    // pipelined instruction port, read every available lookup slot rather
    // than gating its RAM enable with the late EX redirect/flush or queue
    // backpressure. Only gnt captures a transaction and only !stale returns
    // its token; unused reads cannot issue a bus access, fill, or fault.
    wire cache_read_slot=(state==IDLE)||(PIPE_FETCH&&(state==CACHE_LOOKUP)&&cache_hit)||restart_slot||fetch_next_slot;
    wire cache_lookup=((PIPE_FETCH ? cache_read_slot : gnt)&&direct_cache)||(state==CACHE_REQUEST);
    wire [31:0] cache_addr=((state==CACHE_REQUEST)&&!restart_slot) ? bus_addr : hit_physical;
    wire cache_hit;
    wire [31:0] cache_word;
    // A canceled successful RAM read still warms the physically tagged cache.
    // CPU tokens and TLB fills remain canceled. The fabric drains older stores
    // before a read and blocks new store enqueueing through its completion;
    // later stores snoop the pending fill as well as committed cache lines.
    wire cache_fill=(CACHE_LINES>0)&&(state==ACCESS_WAIT)&&bus_done&&!bus_error&&!we_q&&
                    (`IS_INSTR_MEM(bus_addr)||`IS_DATA_MEM(bus_addr));
    physical_l1_cache #(.LINES(CACHE_LINES),.REGISTER_WRITES(PIPE_FETCH)) l1 (
        .clk(clk),.rst(rst),.lookup(cache_lookup),.lookup_addr(cache_addr),
        .hit(cache_hit),.word_data(cache_word),
        .fill(cache_fill),.fill_addr(bus_addr),.fill_data(bus_line),
        .snoop(snoop),.snoop_addr(snoop_addr),.snoop_data(snoop_data),
        .snoop_be(snoop_be),.snoop_error(snoop_error)
    );
    wire fill=(state==PTE_WAIT)&&bus_done&&!bus_error&&pte_valid&&leaf&&
              permission_ok&&(!level||bus_rdata[19:10]==0)&&
              !walk_discard&&!invalidate&&!stale;
    // Only one lookup output is needed per board port; synthesis prunes the
    // unused second lookup without modifying the shared upstream module.
    sv32_tlb tlb (
        .clk(clk),.rst(rst),.flush(invalidate),
        .instr_vaddr(va),.instr_hit(tlb_hit),.instr_pte(tlb_pte),
        .instr_megapage(tlb_megapage),
        .data_vaddr(32'b0),.data_hit(),.data_pte(),.data_megapage(),
        .fill_en(fill),.fill_vaddr(va_q),.fill_pte(bus_rdata),.fill_megapage(level)
    );
    function automatic [31:0] loaded;
        input [31:0] value;
        input [2:0] kind;
        begin
            case(kind)
                0: loaded={{24{value[7]}},value[7:0]};
                1: loaded={{16{value[15]}},value[15:0]};
                4: loaded={24'b0,value[7:0]};
                5: loaded={16'b0,value[15:0]};
                default: loaded=value;
            endcase
        end
    endfunction
    // Both IDLE and a returning pipelined hit accept the same transaction.
    task automatic capture_request;
        begin
            va_q<=va; satp_q<=satp; data_q<=wdata; privilege_q<=privilege;
            translate_q<=translate; we_q<=we; intent_q<=write_intent;
            sum_q<=sum; mxr_q<=mxr; be_q<=be; type_q<=load_type;
            level<=1; fault_q<=translate&&(satp[21:20]!=0); access_fault_q<=0;
            if(PIPE_FETCH) response_q<=32'h13;
            bus_addr<=translate ? ({satp[19:0],12'b0}+{20'b0,va[31:22],2'b0}) : va;
            state<=translate ? ((satp[21:20]!=0) ? DONE : PTE_REQ) : ACCESS_REQ;
            if(translate&&satp[21:20]==0&&tlb_hit) begin
                bus_addr<=hit_physical;
                fault_q<=!hit_permitted;
                state<=hit_permitted ? ACCESS_REQ : DONE;
            end
            if(direct_cache) begin bus_addr<=hit_physical; state<=CACHE_LOOKUP; end
            if(PIPE_FETCH&&fast_translation&&
               !(`IS_INSTR_MEM(hit_physical)||`IS_DATA_MEM(hit_physical))) begin
                bus_addr<=hit_physical; response_q<=32'h13;
                access_fault_q<=1; state<=DONE;
            end
        end
    endtask
    assign rdata=fetch_complete ? (bus_error ? 32'h13 : bus_rdata) : (state==CACHE_LOOKUP) ? (FETCH ? cache_word : loaded(cache_word,type_q)) : response_q;
    always @(posedge clk) begin
        if(rst) begin cache_hits<=0;cache_misses<=0;store_wait_cycles<=0;end
        else begin
            if(state==CACHE_LOOKUP&&!stale) begin
                if(cache_hit) cache_hits<=cache_hits+1'b1;
                else cache_misses<=cache_misses+1'b1;
            end
            if(we_q&&((state==ACCESS_REQ)||(state==ACCESS_WAIT)))
                store_wait_cycles<=store_wait_cycles+1'b1;
        end
    end
    always @(posedge clk) begin
        if(rst) begin satp_seen<=0; walk_discard<=0; end
        else begin
            satp_seen<=satp;
            if(restart_gnt) walk_discard<=0;
            else if((invalidate||(PIPE_FETCH&&(fetch_cancel||context_changed)))&&state!=IDLE) walk_discard<=1;
            else if(state==IDLE) walk_discard<=0;
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; bus_addr<=0; va_q<=0; satp_q<=0; data_q<=0;
            privilege_q<=3; translate_q<=0; we_q<=0; intent_q<=0;
            sum_q<=0; mxr_q<=0; be_q<=0; type_q<=2; level<=1;
            fault_q<=0; access_fault_q<=0; fatal_error<=0; response_q<=32'h13;
        end else if(restart_gnt) capture_request();
        else if(PIPE_FETCH&&state!=IDLE&&stale) begin
            // Granted bus operations cannot be withdrawn. Drain their response
            // without a CPU token or TLB fill. Successful RAM reads may populate
            // the physical cache. A grant may occur on this
            // same cancel edge because bus_req deliberately uses only registers.
            case(state)
                PTE_REQ: state<=(bus_req&&bus_gnt) ? PTE_WAIT : IDLE;
                ACCESS_REQ: state<=(bus_req&&bus_gnt) ? ACCESS_WAIT : IDLE;
                PTE_WAIT, ACCESS_WAIT: if(bus_done) state<=IDLE;
                default: state<=IDLE;
            endcase
        end else case(state)
            IDLE: if(gnt) capture_request();
            PTE_REQ: begin
                if(!ram_pte) begin
                    fault_q<=!PIPE_FETCH; access_fault_q<=PIPE_FETCH;
                    response_q<=32'h13; state<=DONE;
                end
                else if(bus_gnt) state<=PTE_WAIT;
            end
            PTE_WAIT: if(bus_done) begin
                if(bus_error) begin
                    if(PIPE_FETCH) begin access_fault_q<=1; fault_q<=0; response_q<=32'h13; state<=DONE; end
                    else begin fatal_error<=1; state<=IDLE; end
                end
                else if(!pte_valid || (leaf && (!permission_ok ||
                        (level && bus_rdata[19:10]!=0))) || (!leaf&&!level) ||
                        (!leaf&&(bus_rdata[7:6]!=0 || bus_rdata[4]))) begin
                    fault_q<=1; response_q<=32'h13; state<=DONE;
                end else if(leaf) begin
                    bus_addr<=leaf_physical;
                    if(PIPE_FETCH&&!(`IS_INSTR_MEM(leaf_physical)||`IS_DATA_MEM(leaf_physical))) begin
                        access_fault_q<=1; response_q<=32'h13; state<=DONE;
                    end else state<=((CACHE_LINES>0)&&!we_q&&
                            (`IS_INSTR_MEM(leaf_physical)||`IS_DATA_MEM(leaf_physical))) ?
                           CACHE_REQUEST : ACCESS_REQ;
                end else begin
                    bus_addr<={bus_rdata[29:10],12'b0}+{20'b0,va_q[21:12],2'b0};
                    level<=0; state<=PTE_REQ;
                end
            end
            CACHE_REQUEST: state<=CACHE_LOOKUP;
            CACHE_LOOKUP: begin
                // A redirected fetch is dropped just as on the slow path.
                if(PIPE_FETCH&&cache_hit&&gnt) capture_request();
                else if(stale||cache_hit) state<=IDLE;
                else state<=ACCESS_REQ;
            end
            ACCESS_REQ: begin
                if(PIPE_FETCH&&!ram_pte) begin access_fault_q<=1; response_q<=32'h13; state<=DONE; end
                else if(bus_gnt) state<=ACCESS_WAIT;
            end
            ACCESS_WAIT: if(bus_done) begin
                if(fetch_complete) begin
                    if(gnt) capture_request(); else state<=IDLE;
                end else if(bus_error) begin
                    if(PIPE_FETCH) begin access_fault_q<=1; fault_q<=0; response_q<=32'h13; state<=DONE; end
                    else begin fatal_error<=1; state<=IDLE; end
                end
                else begin
                    response_q<=FETCH ? bus_rdata : loaded(bus_rdata,type_q);
                    state<=(EARLY_STORE_RESPONSE&&!FETCH&&we_q) ? IDLE : DONE;
                end
            end
            DONE: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
