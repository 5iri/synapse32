`default_nettype none
`include "memory_map.vh"
// Uncached Sv32 front end. Snapshot an access, fetch PTEs over a physical bus,
// and return exactly one response. Svade matches upstream: A/D clear faults.
// No TLB means SFENCE.VMA has no cached translations to invalidate.
module sv32_bus_port #(parameter FETCH=0) (
    input wire clk, rst,
    input wire req, we, write_intent, translate,
    input wire [31:0] va, satp, wdata,
    input wire [1:0] privilege,
    input wire sum, mxr,
    input wire [3:0] be,
    input wire [2:0] load_type,
    output wire gnt, rvalid, page_fault,
    output reg [31:0] rdata,
    output wire bus_req,
    output wire bus_we,
    output reg [31:0] bus_addr,
    output wire [31:0] bus_wdata,
    output wire [3:0] bus_be,
    input wire bus_gnt, bus_done,
    input wire [31:0] bus_rdata,
    input wire bus_error,
    output reg fatal_error
);
    localparam IDLE=0, PTE_REQ=1, PTE_WAIT=2, ACCESS_REQ=3, ACCESS_WAIT=4, DONE=5;
    reg [2:0] state;
    reg [31:0] va_q, satp_q, data_q;
    reg [1:0] privilege_q;
    reg translate_q, we_q, intent_q, sum_q, mxr_q, level, fault_q;
    reg [3:0] be_q;
    reg [2:0] type_q;
    wire ram_pte=`IS_INSTR_MEM(bus_addr)||`IS_DATA_MEM(bus_addr);
    wire stale=FETCH && ((va_q!=va)||(satp_q!=satp)||
                       (translate_q!=translate)||(privilege_q!=privilege));
    assign gnt=req&&(state==IDLE)&&!fatal_error;
    assign rvalid=(state==DONE)&&!stale;
    assign page_fault=rvalid&&fault_q;
    assign bus_req=((state==PTE_REQ)&&ram_pte)||(state==ACCESS_REQ);
    assign bus_we=(state==ACCESS_REQ)&&we_q;
    assign bus_wdata=data_q;
    assign bus_be=(state==ACCESS_REQ) ? be_q : 4'b1111;
    wire pte_valid=bus_rdata[0] && !(bus_rdata[2]&&!bus_rdata[1]) &&
                   (bus_rdata[31:30]==0);
    wire leaf=bus_rdata[1]||bus_rdata[3];
    wire permission_ok=(privilege_q==0 ? bus_rdata[4] :
                        (!bus_rdata[4] || (!FETCH&&sum_q))) &&
                       bus_rdata[6] &&
                       (FETCH ? bus_rdata[3] :
                        (intent_q ? (bus_rdata[2]&&bus_rdata[7]) :
                         (bus_rdata[1]||(mxr_q&&bus_rdata[3]))));
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
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; bus_addr<=0; va_q<=0; satp_q<=0; data_q<=0;
            privilege_q<=3; translate_q<=0; we_q<=0; intent_q<=0;
            sum_q<=0; mxr_q<=0; be_q<=0; type_q<=2; level<=1;
            fault_q<=0; fatal_error<=0; rdata<=32'h13;
        end else case(state)
            IDLE: if(gnt) begin
                va_q<=va; satp_q<=satp; data_q<=wdata; privilege_q<=privilege;
                translate_q<=translate; we_q<=we; intent_q<=write_intent;
                sum_q<=sum; mxr_q<=mxr; be_q<=be; type_q<=load_type;
                level<=1; fault_q<=translate&&(satp[21:20]!=0);
                bus_addr<=translate ? ({satp[19:0],12'b0}+{20'b0,va[31:22],2'b0}) : va;
                state<=translate ? ((satp[21:20]!=0) ? DONE : PTE_REQ) : ACCESS_REQ;
            end
            PTE_REQ: begin
                if(!ram_pte) begin fault_q<=1; rdata<=32'h13; state<=DONE; end
                else if(bus_gnt) state<=PTE_WAIT;
            end
            PTE_WAIT: if(bus_done) begin
                if(bus_error) begin fatal_error<=1; state<=IDLE; end
                else if(!pte_valid || (leaf && (!permission_ok ||
                        (level && bus_rdata[19:10]!=0))) || (!leaf&&!level) ||
                        (!leaf&&(bus_rdata[7:6]!=0 || bus_rdata[4]))) begin
                    fault_q<=1; rdata<=32'h13; state<=DONE;
                end else if(leaf) begin
                    bus_addr<=level ? {bus_rdata[29:20],va_q[21:0]} :
                                      {bus_rdata[29:10],va_q[11:0]};
                    state<=ACCESS_REQ;
                end else begin
                    bus_addr<={bus_rdata[29:10],12'b0}+{20'b0,va_q[21:12],2'b0};
                    level<=0; state<=PTE_REQ;
                end
            end
            ACCESS_REQ: if(bus_gnt) state<=ACCESS_WAIT;
            ACCESS_WAIT: if(bus_done) begin
                if(bus_error) begin fatal_error<=1; state<=IDLE; end
                else begin rdata<=FETCH ? bus_rdata : loaded(bus_rdata,type_q); state<=DONE; end
            end
            DONE: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
