`default_nettype none
// One outstanding physical transaction. All AXI transfers are 16-byte beats;
// byte strobes select the CPU's byte/halfword/word within that beat.
module axi_word_bridge (
    input wire clk, rst,
    input wire req, we,
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
    localparam IDLE=0, READ_ADDR=1, READ_DATA=2, WRITE=3, RESPONSE=4;
    reg [2:0] state;
    reg aw_sent, w_sent;
    reg [3:0] offset;
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
        end else begin
            done<=0;
            case(state)
                IDLE: if(req&&ready) begin
                    axi_addr<={addr[27:4],4'b0}; offset<=addr[3:0]; error<=0;
                    wdata<={96'b0,data} << (addr[3:0]*8);
                    wstrb<={12'b0,be} << addr[3:0];
                    aw_sent<=0; w_sent<=0;
                    state<=we ? WRITE : READ_ADDR;
                end
                READ_ADDR: if(arready) state<=READ_DATA;
                READ_DATA: if(rvalid) begin
                    result<=32'(rdata >> (offset*8));
                    error<=(rresp!=0)||!rlast; done<=1; state<=IDLE;
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
