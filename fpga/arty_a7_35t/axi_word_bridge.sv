`default_nettype none
// One outstanding physical transaction. All AXI transfers are 16-byte beats;
// byte strobes select the CPU's byte/halfword/word within that beat.
// Separate physical I/D caches, each read-allocate and direct-mapped. All
// writes are synchronous write-through and snoop BOTH banks by byte enable.
// The instruction cache is therefore coherent even before FENCE.I; the CPU
// still serializes/refetches at FENCE.I to discard old pipeline responses.
module axi_word_bridge #(parameter CACHE_LINES=256, ICACHE_LINES=256) (
    input wire clk, rst,
    input wire req, we, cache_read, cache_instr,
    input wire [27:0] addr,
    input wire [31:0] data,
    input wire [3:0] be,
    output wire ready,
    output reg done, error,
    output reg [31:0] result,
    output reg [127:0] read_line,
    output wire read_wait, write_wait,
    output reg [27:0] axi_addr,
    output wire arvalid, rready, awvalid, wvalid, bready,
    input wire arready, rvalid, rlast, awready, wready, bvalid,
    input wire [127:0] rdata,
    input wire [1:0] rresp, bresp,
    output reg [127:0] wdata,
    output reg [15:0] wstrb
);
    localparam IDLE=0, READ_ADDR=1, READ_DATA=2, WRITE=3, RESPONSE=4, LOOKUP=5;
    reg [2:0] state;
    reg aw_sent, w_sent;
    reg [3:0] offset;
    reg data_cache_q, instr_cache_q;
    wire d_hit, i_hit;
    wire [127:0] d_line, i_line;
    wire good_read=(rresp==0)&&rlast;
    wire refill=(state==READ_DATA)&&rvalid&&good_read;
    wire store_done=(state==RESPONSE)&&bvalid;
    wire lookup=req&&ready;
    axi_read_cache #(.LINES(CACHE_LINES)) dcache (
        .clk(clk),.rst(rst),.lookup(lookup),.addr(addr),
        .hit(d_hit),.cached_line(d_line),.fill(refill&&data_cache_q),.fill_data(rdata),
        .store_done(store_done),.store_error(bresp!=0),.store_data(wdata),.store_be(wstrb)
    );
    axi_read_cache #(.LINES(ICACHE_LINES)) icache (
        .clk(clk),.rst(rst),.lookup(lookup),.addr(addr),
        .hit(i_hit),.cached_line(i_line),.fill(refill&&instr_cache_q),.fill_data(rdata),
        .store_done(store_done),.store_error(bresp!=0),.store_data(wdata),.store_be(wstrb)
    );
    assign ready=(state==IDLE)&&!done;
    assign read_wait=(state==READ_ADDR)||(state==READ_DATA);
    assign write_wait=(state==WRITE)||(state==RESPONSE);
    assign arvalid=(state==READ_ADDR);
    assign rready=(state==READ_DATA);
    assign awvalid=(state==WRITE)&&!aw_sent;
    assign wvalid=(state==WRITE)&&!w_sent;
    assign bready=(state==RESPONSE);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; error<=0; result<=0; offset<=0;
            axi_addr<=0; wdata<=0; wstrb<=0; aw_sent<=0; w_sent<=0;
            data_cache_q<=0; instr_cache_q<=0; read_line<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(req&&ready) begin
                    axi_addr<={addr[27:4],4'b0}; offset<=addr[3:0]; error<=0;
                    wdata<={96'b0,data} << (addr[3:0]*8);
                    wstrb<={12'b0,be} << addr[3:0];
                    aw_sent<=0; w_sent<=0;
                    data_cache_q<=(CACHE_LINES>0)&&cache_read;
                    instr_cache_q<=(ICACHE_LINES>0)&&cache_instr;
                    state<=we ? WRITE : (((CACHE_LINES>0&&cache_read)||
                                          (ICACHE_LINES>0&&cache_instr)) ? LOOKUP : READ_ADDR);
                end
                LOOKUP: begin
                    if((data_cache_q&&d_hit)||(instr_cache_q&&i_hit)) begin
                        result<=32'((instr_cache_q ? i_line : d_line) >> (offset*8));
                        read_line<=instr_cache_q ? i_line : d_line;
                        done<=1; state<=IDLE;
                    end else state<=READ_ADDR;
                end
                READ_ADDR: if(arready) state<=READ_DATA;
                READ_DATA: if(rvalid) begin
                    result<=32'(rdata >> (offset*8));
                    if(good_read) read_line<=rdata;
                    error<=!good_read; done<=1; state<=IDLE;
                end
                WRITE: begin
                    if(awready) aw_sent<=1;
                    if(wready) w_sent<=1;
                    if((aw_sent||awready)&&(w_sent||wready)) state<=RESPONSE;
                end
                RESPONSE: if(bvalid) begin
                    error<=(bresp!=0); result<=0; done<=1; state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// One cache bank. No dirty state and no independent bus master: the serialized
// bridge presents every write to both banks before reporting completion.
module axi_read_cache #(parameter LINES=256) (
    input wire clk, rst, lookup,
    input wire [27:0] addr,
    output reg hit,
    output reg [127:0] cached_line,
    input wire fill,
    input wire [127:0] fill_data,
    input wire store_done, store_error,
    input wire [127:0] store_data,
    input wire [15:0] store_be
);
    localparam COUNT=(LINES>0) ? LINES : 1;
    localparam INDEX_BITS=(COUNT>1) ? $clog2(COUNT) : 1;
    reg [COUNT-1:0] valid;
    reg [23:0] tags[0:COUNT-1];
    (* ram_style="block" *) reg [127:0] data_ram[0:COUNT-1];
    wire [INDEX_BITS-1:0] index=(COUNT>1) ? addr[4+:INDEX_BITS] : {INDEX_BITS{1'b0}};
    reg [INDEX_BITS-1:0] index_q;
    reg [23:0] tag_q;
    integer lane;
    initial begin
        if(LINES<0 || LINES>65536 || (LINES>0 && (LINES&(LINES-1))!=0))
            $fatal(1,"Cache lines must be zero or a power of two up to 65536");
    end
    // Synchronous data lookup, no RAM reset, and byte enables infer block RAM.
    always @(posedge clk) begin
        if(lookup) cached_line<=data_ram[index];
        if(!rst && fill) begin
            data_ram[index_q]<=fill_data;
            tags[index_q]<=tag_q;
        end
        if(!rst && store_done && !store_error && hit)
            for(lane=0;lane<16;lane=lane+1)
                if(store_be[lane]) data_ram[index_q][lane*8+:8]<=store_data[lane*8+:8];
    end
    always @(posedge clk) begin
        if(rst) begin valid<=0;hit<=0;index_q<=0;tag_q<=0;end
        else begin
            if(lookup) begin
                index_q<=index;tag_q<=addr[27:4];
                hit<=(LINES>0)&&valid[index]&&(tags[index]==addr[27:4]);
            end
            if(fill) valid[index_q]<=1;
            // An error may mean memory changed partially: invalidate both banks.
            if(store_done&&store_error&&hit) valid[index_q]<=0;
        end
    end
endmodule
