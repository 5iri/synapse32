`default_nettype none
// One outstanding physical transaction. All AXI transfers are 16-byte beats;
// byte strobes select the CPU's byte/halfword/word within that beat.
// Optional direct-mapped, physical data cache: read allocate, write through,
// no write allocate. cache_read qualifies data reads only. ALL writers snoop
// resident lines, including the loader and uncached owners. No dirty state.
module axi_word_bridge #(parameter CACHE_LINES=256) (
    input wire clk, rst,
    input wire req, we, cache_read,
    input wire [27:0] addr,
    input wire [31:0] data,
    input wire [3:0] be,
    output wire ready,
    output reg done, error,
    output reg [31:0] result,
    output reg [27:0] axi_addr,
    output wire arvalid, rready, awvalid, wvalid, bready,
    input wire arready, rvalid, rlast, awready, wready, bvalid,
    input wire [127:0] rdata,
    input wire [1:0] rresp, bresp,
    output reg [127:0] wdata,
    output reg [15:0] wstrb
);
    localparam IDLE=0, READ_ADDR=1, READ_DATA=2, WRITE=3, RESPONSE=4, LOOKUP=5;
    localparam LINES=(CACHE_LINES>0) ? CACHE_LINES : 1;
    localparam INDEX_BITS=(LINES>1) ? $clog2(LINES) : 1;
    reg [2:0] state;
    reg aw_sent, w_sent;
    reg [3:0] offset;
    reg [LINES-1:0] valid;
    reg [23:0] tags[0:LINES-1];
    (* ram_style="block" *) reg [127:0] lines[0:LINES-1];
    reg [127:0] cached_line;
    reg [INDEX_BITS-1:0] index_q;
    wire [INDEX_BITS-1:0] index=(LINES>1) ? addr[4+:INDEX_BITS] : {INDEX_BITS{1'b0}};
    reg cacheable_q, hit_q;
    wire good_read=(rresp==0)&&rlast;
    integer lane;
    initial begin
        if(CACHE_LINES<0 || (CACHE_LINES>0 && (CACHE_LINES&(CACHE_LINES-1))!=0))
            $fatal(1,"CACHE_LINES must be zero or a power of two");
    end
    // Synchronous line lookup and byte enables infer FPGA block RAM. Only the
    // valid bits reset; uninitialized data/tags are never returned as hits.
    always @(posedge clk) begin
        if(req&&ready) cached_line<=lines[index];
        if(!rst && state==READ_DATA && rvalid && good_read && cacheable_q) begin
            lines[index_q]<=rdata;
            tags[index_q]<=axi_addr[27:4];
        end
        if(!rst && state==RESPONSE && bvalid && bresp==0 && hit_q)
            for(lane=0;lane<16;lane=lane+1)
                if(wstrb[lane]) lines[index_q][lane*8+:8]<=wdata[lane*8+:8];
    end
    assign ready=(state==IDLE)&&!done;
    assign arvalid=(state==READ_ADDR);
    assign rready=(state==READ_DATA);
    assign awvalid=(state==WRITE)&&!aw_sent;
    assign wvalid=(state==WRITE)&&!w_sent;
    assign bready=(state==RESPONSE);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; error<=0; result<=0; offset<=0;
            axi_addr<=0; wdata<=0; wstrb<=0; aw_sent<=0; w_sent<=0;
            valid<=0; index_q<=0; cacheable_q<=0; hit_q<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(req&&ready) begin
                    axi_addr<={addr[27:4],4'b0}; offset<=addr[3:0]; error<=0;
                    wdata<={96'b0,data} << (addr[3:0]*8);
                    wstrb<={12'b0,be} << addr[3:0];
                    aw_sent<=0; w_sent<=0;
                    index_q<=index;
                    hit_q<=(CACHE_LINES>0)&&valid[index]&&(tags[index]==addr[27:4]);
                    cacheable_q<=(CACHE_LINES>0)&&cache_read;
                    state<=we ? WRITE : ((CACHE_LINES>0&&cache_read) ? LOOKUP : READ_ADDR);
                end
                LOOKUP: begin
                    if(hit_q) begin
                        result<=32'(cached_line >> (offset*8));
                        done<=1; state<=IDLE;
                    end else state<=READ_ADDR;
                end
                READ_ADDR: if(arready) state<=READ_DATA;
                READ_DATA: if(rvalid) begin
                    result<=32'(rdata >> (offset*8));
                    error<=!good_read; done<=1; state<=IDLE;
                    if(good_read&&cacheable_q) valid[index_q]<=1;
                end
                WRITE: begin
                    if(awready) aw_sent<=1;
                    if(wready) w_sent<=1;
                    if((aw_sent||awready)&&(w_sent||wready)) state<=RESPONSE;
                end
                RESPONSE: if(bvalid) begin
                    error<=(bresp!=0); result<=0; done<=1; state<=IDLE;
                    // A failed store may have partially changed memory. Force
                    // the next reader to consult DDR instead of a stale hit.
                    if(bresp!=0&&hit_q) valid[index_q]<=0;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
