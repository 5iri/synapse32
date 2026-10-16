`default_nettype none
// Physical, direct-mapped, read-allocate L1 bank. The synchronous data read
// uses one BRAM port; fills and completed write-through snoops share the other.
// A shared lower bus permits only one fill or completed store per cycle.
module physical_l1_cache #(parameter LINES=256) (
    input wire clk, rst,
    input wire lookup,
    input wire [31:0] lookup_addr,
    output reg hit,
    output wire [31:0] word_data,
    input wire fill,
    input wire [31:0] fill_addr,
    input wire [127:0] fill_data,
    input wire snoop,
    input wire [31:0] snoop_addr, snoop_data,
    input wire [3:0] snoop_be,
    input wire snoop_error
);
    localparam COUNT=(LINES>0) ? LINES : 1;
    localparam INDEX_BITS=(COUNT>1) ? $clog2(COUNT) : 1;
    reg [COUNT-1:0] valid;
    reg [27:0] tags[0:COUNT-1];
    (* ram_style="block" *) reg [127:0] data_ram[0:COUNT-1];
    reg [127:0] line_q;
    reg [127:0] forward_data_q;
    reg [15:0] forward_mask_q;
    reg [3:0] offset_q;
    wire [INDEX_BITS-1:0] lookup_index=(COUNT>1) ? lookup_addr[4+:INDEX_BITS] : {INDEX_BITS{1'b0}};
    wire [INDEX_BITS-1:0] fill_index=(COUNT>1) ? fill_addr[4+:INDEX_BITS] : {INDEX_BITS{1'b0}};
    wire [INDEX_BITS-1:0] snoop_index=(COUNT>1) ? snoop_addr[4+:INDEX_BITS] : {INDEX_BITS{1'b0}};
    wire snoop_hit=(LINES>0)&&valid[snoop_index]&&(tags[snoop_index]==snoop_addr[31:4]);
    wire lookup_snooped=snoop&&(lookup_addr[31:4]==snoop_addr[31:4]);
    wire lookup_fill_collision=fill&&(lookup_index==fill_index);
    wire [127:0] snoop_line={96'b0,snoop_data} << (snoop_addr[3:0]*8);
    wire [15:0] snoop_strobes={12'b0,snoop_be} << snoop_addr[3:0];
    wire [INDEX_BITS-1:0] write_index=fill ? fill_index : snoop_index;
    wire [127:0] write_data=fill ? fill_data : snoop_line;
    wire [15:0] write_mask=rst ? 16'b0 : (fill ? 16'hffff :
        ((snoop&&snoop_hit&&!snoop_error) ? snoop_strobes : 16'b0));
    wire [127:0] forwarded_line;
    genvar byte_lane;
    generate for(byte_lane=0;byte_lane<16;byte_lane=byte_lane+1) begin: forwarding
        assign forwarded_line[byte_lane*8+:8]=forward_mask_q[byte_lane] ?
            forward_data_q[byte_lane*8+:8] : line_q[byte_lane*8+:8];
    end endgenerate
    integer lane,forward_lane;
    assign word_data=32'(forwarded_line >> (offset_q*8));
    initial begin
        if(LINES<0 || LINES>65536 || (LINES>0 && (LINES&(LINES-1))!=0))
            $fatal(1,"L1 lines must be zero or a power of two up to 65536");
    end
    // Canonical simple dual-port BRAM: one unmodified synchronous read
    // register and one common byte-write address. Keep forwarding OUTSIDE
    // this register, or synthesis cannot absorb the read into block RAM.
    always @(posedge clk) begin
        if(lookup) line_q<=data_ram[lookup_index];
        for(lane=0;lane<16;lane=lane+1)
            if(write_mask[lane]) data_ram[write_index][lane*8+:8]<=write_data[lane*8+:8];
    end
    always @(posedge clk) begin
        if(lookup) begin
            forward_mask_q<=lookup_fill_collision ? 16'hffff : 16'b0;
            forward_data_q<=lookup_fill_collision ? fill_data : snoop_line;
            // Both RAM ports can touch the same line at a completed store.
            // Forward the written lanes instead of relying on RAM collision mode.
            if(lookup_snooped&&!snoop_error&&snoop_hit)
                for(forward_lane=0;forward_lane<16;forward_lane=forward_lane+1)
                    if(snoop_strobes[forward_lane]) begin
                        forward_mask_q[forward_lane]<=1'b1;
                        forward_data_q[forward_lane*8+:8]<=snoop_line[forward_lane*8+:8];
                    end
        end
    end
    always @(posedge clk) begin
        if(rst) begin valid<=0;hit<=0;offset_q<=0;end
        else begin
            if(lookup) begin
                offset_q<=lookup_addr[3:0];
                hit<=(LINES>0)&&
                     (lookup_fill_collision ? lookup_addr[31:4]==fill_addr[31:4] :
                                              (valid[lookup_index]&&(tags[lookup_index]==lookup_addr[31:4])))&&
                     !(lookup_snooped&&snoop_error);
            end
            if(fill) begin valid[fill_index]<=1;tags[fill_index]<=fill_addr[31:4];end
            if(snoop&&snoop_hit&&snoop_error) valid[snoop_index]<=0;
        end
    end
endmodule
