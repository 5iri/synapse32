`default_nettype none
// Physical Arty A7-35T top. DDR3 pin locations are supplied by the MIG project.
module arty_linux_top #(parameter BOOT_BAUD=1000000, CPU_DIVIDE=20, DCACHE_LINES=256, ICACHE_LINES=256,
                       FAST_L1=1, STORE_BUFFER_DEPTH=4, FAST_MULTIPLY=1, FETCH_QUEUE=1) (
    input wire clk100, reset_n, uart_rx,
    output wire uart_tx,
    output wire [3:0] led,
    inout wire [15:0] ddr3_dq,
    inout wire [1:0] ddr3_dqs_n, ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n,
    output wire [0:0] ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_odt,
    output wire [1:0] ddr3_dm
);
    wire feedback, feedback_buffered, ref200_raw, ref200, cpu50_raw, cpu50, locked;
    // The MMCM VCO remains at 1 GHz; DDR's 200 MHz reference is unchanged.
    // Keep loader/UART rates consistent with the selected CPU output divider.
    localparam CPU_CLOCK_HZ=(1000000000+CPU_DIVIDE/2)/CPU_DIVIDE;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.0),.CLKFBOUT_MULT_F(10.0),
        .DIVCLK_DIVIDE(1),.CLKOUT0_DIVIDE_F(5.0),.CLKOUT1_DIVIDE(CPU_DIVIDE)) reference_clock (
        .CLKIN1(clk100),.CLKFBIN(feedback_buffered),.RST(!reset_n),.PWRDWN(1'b0),
        .CLKFBOUT(feedback),.CLKOUT0(ref200_raw),.LOCKED(locked),
        .CLKFBOUTB(),.CLKOUT0B(),.CLKOUT1(cpu50_raw),.CLKOUT1B(),.CLKOUT2(),.CLKOUT2B(),
        .CLKOUT3(),.CLKOUT3B(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6()
    );
    BUFG feedback_clock(.I(feedback),.O(feedback_buffered));
    BUFG reference_buffer(.I(ref200_raw),.O(ref200));
    BUFG cpu_clock_buffer(.I(cpu50_raw),.O(cpu50));
    wire calibrated, booted, fault;
    wire [31:0] pc;
    arty_ddr3_top #(.SERIAL_BOOT(1),.SEPARATE_CPU_CLOCK(1),.CLOCK_HZ(CPU_CLOCK_HZ),
        .BOOT_BAUD(BOOT_BAUD),.DCACHE_LINES(DCACHE_LINES),.ICACHE_LINES(ICACHE_LINES),.FAST_L1(FAST_L1),
        .STORE_BUFFER_DEPTH(STORE_BUFFER_DEPTH),.FAST_MULTIPLY(FAST_MULTIPLY),.FETCH_QUEUE(FETCH_QUEUE)) system (
        .cpu_clk50(cpu50),.clk100(clk100),.clk_ref200(ref200),.reset_n(reset_n&&locked),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.calibrated(calibrated),
        .boot_done(booted),.fault(fault),.pc_debug(pc),
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),.ddr3_we_n(ddr3_we_n),.ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),.ddr3_ck_n(ddr3_ck_n),.ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),.ddr3_odt(ddr3_odt),.ddr3_dm(ddr3_dm)
    );
    assign led={fault,booted,calibrated,locked};
endmodule
