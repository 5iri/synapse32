`default_nettype none
// Host protocol: "S32!", uint32 length, length bytes, uint32 CRC32 (all LE).
// The payload starts at 0x80000000. Reply K after DDR writes and CRC succeed,
// then release the CPU. Invalid length, CRC or write overrun replies E.
module uart_boot_loader #(parameter CLOCK_HZ=81250000, BAUD=115200) (
    input wire clk, rst, enabled, rx,
    output wire tx,
    output wire req,
    output wire [31:0] addr, data,
    input wire ready, done, bus_fault,
    output reg finish, error
);
    localparam BIT_CYCLES=(CLOCK_HZ+BAUD/2)/BAUD;
    reg [1:0] rx_sync=3;
    (* ASYNC_REG="TRUE" *) reg rx_meta=1;
    always @(posedge clk) begin rx_meta<=rx; rx_sync<={rx_sync[0],rx_meta}; end
    reg [1:0] rx_state;
    reg [15:0] rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift, byte_data;
    reg byte_valid;
    always @(posedge clk) begin
        byte_valid<=0;
        if(rst||!enabled) begin rx_state<=0; rx_count<=0; rx_bit<=0; rx_shift<=0; byte_data<=0; end
        else case(rx_state)
            0: if(!rx_sync[1]) begin rx_count<=16'(BIT_CYCLES/2-1); rx_state<=1; end
            1: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else if(!rx_sync[1]) begin rx_count<=16'(BIT_CYCLES-1); rx_bit<=0; rx_state<=2; end
               else rx_state<=0;
            2: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else begin
                   rx_shift[rx_bit]<=rx_sync[1]; rx_count<=16'(BIT_CYCLES-1);
                   if(rx_bit==7) rx_state<=3; else rx_bit<=rx_bit+1'b1;
               end
            3: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else begin
                   if(rx_sync[1]) begin byte_data<=rx_shift; byte_valid<=1; end
                   rx_state<=0;
               end
        endcase
    end
    reg tx_busy, tx_start;
    reg [9:0] tx_shift;
    reg [15:0] tx_count;
    reg [3:0] tx_bit;
    reg [7:0] reply;
    assign tx=tx_busy ? tx_shift[0] : 1'b1;
    always @(posedge clk) begin
        if(rst) begin tx_busy<=0;tx_shift<=10'h3ff;tx_count<=0;tx_bit<=0; end
        else if(tx_start&&!tx_busy) begin
            tx_busy<=1;tx_shift<={1'b1,reply,1'b0};tx_count<=16'(BIT_CYCLES-1);tx_bit<=0;
        end else if(tx_busy) begin
            if(tx_count!=0) tx_count<=tx_count-1'b1;
            else begin
                tx_shift<={1'b1,tx_shift[9:1]}; tx_count<=16'(BIT_CYCLES-1);
                if(tx_bit==9) tx_busy<=0; else tx_bit<=tx_bit+1'b1;
            end
        end
    end
    function automatic [31:0] crc_byte(input [31:0] previous,input [7:0] value);
        reg [31:0] c; integer k;
        begin
            c=previous^{24'b0,value};
            for(k=0;k<8;k=k+1) c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    localparam MAGIC=0,LENGTH=1,PAYLOAD=2,WRITE_REQ=3,WRITE_WAIT=4,
               CHECKSUM=5,REPLY=6,REPLY_WAIT=7,FINISHED=8,REPLY_START=9;
    reg [3:0] state;
    reg [1:0] byte_index;
    reg [31:0] length, received, word_data, crc, expected_crc;
    assign req=(state==WRITE_REQ);
    assign addr=32'h80000000+received-4;
    assign data=word_data;
    always @(posedge clk) begin
        finish<=0;tx_start<=0;
        if(rst) begin
            state<=MAGIC;byte_index<=0;length<=0;received<=0;
            word_data<=0;crc<=32'hffffffff;expected_crc<=0;error<=0;reply<=8'h45;
        end else if(enabled&&bus_fault&&state!=REPLY&&state!=REPLY_START&&state!=REPLY_WAIT&&state!=FINISHED) begin
            error<=1;reply<=8'h45;state<=REPLY;
        end else if(enabled) case(state)
            MAGIC: if(byte_valid) begin
                if(byte_data==(byte_index==0 ? 8'h53 : byte_index==1 ? 8'h33 : byte_index==2 ? 8'h32 : 8'h21)) begin
                    byte_index<=byte_index+1'b1;
                    if(byte_index==3) state<=LENGTH;
                end else byte_index<=0;
            end
            LENGTH: if(byte_valid) begin
                length[byte_index*8+:8]<=byte_data;byte_index<=byte_index+1'b1;
                if(byte_index==3) begin
                    if({byte_data,length[23:0]}==0 || {byte_data,length[23:0]}>32'h04000000 || length[1:0]!=0) begin
                        error<=1; reply<=8'h45;state<=REPLY;
                    end else state<=PAYLOAD;
                end
            end
            PAYLOAD: if(byte_valid) begin
                word_data[byte_index*8+:8]<=byte_data; byte_index<=byte_index+1'b1;
                received<=received+1'b1;crc<=crc_byte(crc,byte_data);
                if(byte_index==3) state<=WRITE_REQ;
            end
            WRITE_REQ: begin
                if(byte_valid) begin error<=1;reply<=8'h45;state<=REPLY;end
                else if(ready) state<=WRITE_WAIT;
            end
            WRITE_WAIT: begin
                if(byte_valid) begin error<=1;reply<=8'h45;state<=REPLY;end
                else if(done) state<=received==length ? CHECKSUM : PAYLOAD;
            end
            CHECKSUM: if(byte_valid) begin
                expected_crc[byte_index*8+:8]<=byte_data;byte_index<=byte_index+1'b1;
                if(byte_index==3) begin
                    error<=({byte_data,expected_crc[23:0]}!=~crc);
                    reply<=({byte_data,expected_crc[23:0]}==~crc) ? 8'h4b : 8'h45;
                    state<=REPLY;
                end
            end
            REPLY: begin tx_start<=1;state<=REPLY_START;end
            REPLY_START: if(tx_busy) state<=REPLY_WAIT;
            REPLY_WAIT: if(!tx_busy) begin
                if(!error) finish<=1;
                state<=FINISHED;
            end
            FINISHED: state<=FINISHED;
            default: state<=MAGIC;
        endcase
    end
endmodule
