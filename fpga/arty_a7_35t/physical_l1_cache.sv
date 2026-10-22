`default_nettype none
// Physical, direct-mapped, read-allocate L1 bank. The synchronous data read
// uses one BRAM port; fills and write-through snoops share the other.
// The caller serializes the incoming fill/snoop stream, even with posted stores.
module physical_l1_cache #(parameter LINES=256, REGISTER_WRITES=0) (
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
    wire pending_fill, pending_invalidate;
    wire [INDEX_BITS-1:0] pending_fill_index, pending_invalidate_index;
    wire [27:0] pending_fill_tag;
    // A pending fill already replaces the old logical line, even before its
    // data and metadata commit. Snoops must never hit the evicted old tag.
    wire snoop_hit=(LINES>0)&&
        ((pending_fill&&(snoop_index==pending_fill_index)) ?
            (pending_fill_tag==snoop_addr[31:4]) :
            (valid[snoop_index]&&(tags[snoop_index]==snoop_addr[31:4])))&&
        !(pending_invalidate&&(snoop_index==pending_invalidate_index));
    wire lookup_resident=(LINES>0)&&
        ((pending_fill&&(lookup_index==pending_fill_index)) ?
            (pending_fill_tag==lookup_addr[31:4]) :
            (valid[lookup_index]&&(tags[lookup_index]==lookup_addr[31:4])))&&
        !(pending_invalidate&&(lookup_index==pending_invalidate_index));
    wire lookup_snooped=snoop&&(lookup_addr[31:4]==snoop_addr[31:4]);
    wire lookup_fill_collision=fill&&(lookup_index==fill_index);
    wire [127:0] snoop_line={96'b0,snoop_data} << (snoop_addr[3:0]*8);
    wire [15:0] snoop_strobes={12'b0,snoop_be} << snoop_addr[3:0];
    wire [INDEX_BITS-1:0] write_index;
    wire [127:0] write_data;
    wire [15:0] write_mask;
    generate if(REGISTER_WRITES) begin: registered_writes
        // Register the complete ordered write-event stream, including snoops.
        // A late fetch cancellation may suppress fill, but cannot select the
        // BRAM's write address/data/byte enables on the same cycle. Capturing
        // fill and snoop data separately also keeps that late control out of
        // the 128-bit input registers. Data, tags and validity commit together;
        // pending metadata and byte forwarding cover the one-cycle delay.
        reg fill_q, invalidate_q;
        reg [INDEX_BITS-1:0] fill_index_q, snoop_index_q;
        reg [27:0] fill_tag_q;
        reg [127:0] fill_data_q, snoop_line_q;
        reg [15:0] snoop_mask_q;
        always @(posedge clk) begin
            fill_q<=!rst&&fill;
            fill_index_q<=fill_index; fill_data_q<=fill_data;
            fill_tag_q<=fill_addr[31:4];
            snoop_index_q<=snoop_index; snoop_line_q<=snoop_line;
            snoop_mask_q<=(!rst&&snoop&&snoop_hit&&!snoop_error) ? snoop_strobes : 16'b0;
            invalidate_q<=!rst&&snoop&&snoop_hit&&snoop_error;
        end
        assign pending_fill=fill_q;
        assign pending_fill_index=fill_index_q;
        assign pending_fill_tag=fill_tag_q;
        assign pending_invalidate=invalidate_q;
        assign pending_invalidate_index=snoop_index_q;
        assign write_index=fill_q ? fill_index_q : snoop_index_q;
        assign write_data=fill_q ? fill_data_q : snoop_line_q;
        assign write_mask=rst ? 16'b0 : (fill_q ? 16'hffff : snoop_mask_q);
    end else begin: direct_writes
        assign pending_fill=0; assign pending_fill_index=0; assign pending_fill_tag=0;
        assign pending_invalidate=0; assign pending_invalidate_index=0;
        assign write_index=fill ? fill_index : snoop_index;
        assign write_data=fill ? fill_data : snoop_line;
        assign write_mask=rst ? 16'b0 : (fill ? 16'hffff :
            ((snoop&&snoop_hit&&!snoop_error) ? snoop_strobes : 16'b0));
    end endgenerate
    wire metadata_fill=REGISTER_WRITES ? pending_fill : fill;
    wire [INDEX_BITS-1:0] metadata_fill_index=REGISTER_WRITES ? pending_fill_index : fill_index;
    wire [27:0] metadata_fill_tag=REGISTER_WRITES ? pending_fill_tag : fill_addr[31:4];
    wire metadata_invalidate=REGISTER_WRITES ? pending_invalidate : (snoop&&snoop_hit&&snoop_error);
    wire [INDEX_BITS-1:0] metadata_invalidate_index=REGISTER_WRITES ? pending_invalidate_index : snoop_index;
    wire lookup_commit_collision=REGISTER_WRITES&&(lookup_index==write_index);
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
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst&&LINES>0&&fill&&snoop)
        $fatal(1,"L1 fill and snoop must be serialized before the write pipeline");
`endif
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
            // Oldest first: the write committing to RAM at this edge, then
            // the current fill, then the current byte snoop. In particular a
            // store immediately after a refill must override the older fill,
            // including when the RAM read and delayed commit collide.
            forward_mask_q<=lookup_commit_collision ? write_mask : 16'b0;
            forward_data_q<=write_data;
            if(lookup_fill_collision) begin
                forward_mask_q<=16'hffff;
                forward_data_q<=fill_data;
            end
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
                     (lookup_fill_collision ? lookup_addr[31:4]==fill_addr[31:4] : lookup_resident)&&
                     !(lookup_snooped&&snoop_error);
            end
            if(metadata_fill) begin
                valid[metadata_fill_index]<=1;tags[metadata_fill_index]<=metadata_fill_tag;
            end
            if(metadata_invalidate) valid[metadata_invalidate_index]<=0;
        end
    end
endmodule
