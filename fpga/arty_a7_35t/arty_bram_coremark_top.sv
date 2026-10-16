`default_nettype none
module arty_bram_coremark_top #(parameter MEM_FILE="coremark_bram.mem") (
    input wire clk100,reset_n,uart_rx,
    output wire uart_tx,output wire [3:0] led
);
    wire feedback,feedback_buf,clock_raw,clock50,locked;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.0),.CLKFBOUT_MULT_F(10.0),
        .DIVCLK_DIVIDE(1),.CLKOUT0_DIVIDE_F(20.0)) pll (
        .CLKIN1(clk100),.CLKFBIN(feedback_buf),.RST(!reset_n),.PWRDWN(1'b0),
        .CLKFBOUT(feedback),.CLKOUT0(clock_raw),.LOCKED(locked),.CLKFBOUTB(),
        .CLKOUT0B(),.CLKOUT1(),.CLKOUT1B(),.CLKOUT2(),.CLKOUT2B(),
        .CLKOUT3(),.CLKOUT3B(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6());
    BUFG fb_buffer(.I(feedback),.O(feedback_buf));
    BUFG cpu_buffer(.I(clock_raw),.O(clock50));
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_sync=3'b111;
    wire reset_source=!reset_n||!locked;
    always @(posedge clock50 or posedge reset_source) begin
        if(reset_source) reset_sync<=3'b111;
        else reset_sync<={reset_sync[1:0],1'b0};
    end
    wire fault,uart_seen;
    bram_coremark_system #(.MEM_FILE(MEM_FILE)) system (
        .clk(clock50),.rst(reset_sync[2]),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .fault(fault),.uart_seen(uart_seen),.pc_debug());
    // LED0=clock locked, LED1=reset released, LED2=CPU UART accessed, LED3=fault.
    assign led={fault,uart_seen,!reset_sync[2],locked};
endmodule
