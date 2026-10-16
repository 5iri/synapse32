`default_nettype none
// DDR3 fabric shared by the board wrapper and component-model simulation.
module arty_ddr3_top #(
    parameter SERIAL_BOOT=0, BOOT_WORDS=256, BOOT_FILE="boot.hex",
    parameter ITERATIVE_MULDIV=1, CLOCK_HZ=81250000, SEPARATE_CPU_CLOCK=0,
    parameter BOOT_BAUD=115200, DCACHE_LINES=256, ICACHE_LINES=256, FAST_L1=0,
    parameter STORE_BUFFER_DEPTH=0, FAST_MULTIPLY=0
) (
    input wire clk100, clk_ref200, reset_n, uart_rx, cpu_clk50,
    output wire uart_tx, calibrated, boot_done, fault,
    output wire [31:0] pc_debug,
    inout wire [15:0] ddr3_dq,
    inout wire [1:0] ddr3_dqs_n, ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n,
    output wire [0:0] ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_odt,
    output wire [1:0] ddr3_dm
);
    wire ui_clk, ui_rst, core_enable;
    reg [1:0] axi_reset=0;
    reg fabric_reset_source=1;
    always @(posedge ui_clk) begin
        if(ui_rst) axi_reset<=0;
        else axi_reset<={axi_reset[0],1'b1};
        // Combine in the source domain, then cross a single registered bit.
        fabric_reset_source<=ui_rst||!axi_reset[1];
    end
    wire fabric_clk=SEPARATE_CPU_CLOCK ? cpu_clk50 : ui_clk;
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_sync=3'b111;
    (* ASYNC_REG="TRUE" *) reg [1:0] cal_sync=0;
    always @(posedge fabric_clk or negedge reset_n) begin
        if(!reset_n) begin reset_sync<=3'b111; cal_sync<=0; end
        else begin
            reset_sync<={reset_sync[1:0],fabric_reset_source};
            cal_sync<={cal_sync[0],calibrated};
        end
    end
    wire rst=reset_sync[2];
    wire [27:0] addr;
    wire arvalid, arready, rvalid, rready, rlast;
    wire awvalid, awready, wvalid, wready, bvalid, bready;
    wire [127:0] rdata,wdata;
    wire [15:0] wstrb;
    wire [1:0] rresp,bresp;
    wire load_req, load_finish, load_ready, load_done, loader_error, loader_tx, cpu_tx;
    wire [31:0] load_addr, load_data;
    wire system_fault;
    (* ASYNC_REG="TRUE" *) reg [1:0] uart_sync=2'b11;
    always @(posedge fabric_clk) uart_sync<={uart_sync[0],uart_rx};
    generate if(SERIAL_BOOT) begin: serial_loader
        uart_boot_loader #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BOOT_BAUD)) loader (
            .clk(fabric_clk),.rst(rst),.enabled(cal_sync[1]&&!boot_done),.rx(uart_rx),
            .tx(loader_tx),.req(load_req),.addr(load_addr),.data(load_data),
            .ready(load_ready),.done(load_done),.bus_fault(system_fault),.finish(load_finish),.error(loader_error)
        );
    end else begin: rom_loader
        assign load_req=0; assign load_finish=0; assign load_addr=0; assign load_data=0;
        assign loader_tx=1; assign loader_error=0;
    end endgenerate
    assign uart_tx=boot_done ? cpu_tx : loader_tx;
    assign fault=system_fault||loader_error;
    synapse_ddr3_system #(.SERIAL_BOOT(SERIAL_BOOT),.BOOT_WORDS(BOOT_WORDS),.BOOT_FILE(BOOT_FILE),
        .ITERATIVE_MULDIV(ITERATIVE_MULDIV),.UART_DIVISOR_SCALE(16),
        .DCACHE_LINES(DCACHE_LINES),.ICACHE_LINES(ICACHE_LINES),.FAST_L1(FAST_L1),
        .STORE_BUFFER_DEPTH(STORE_BUFFER_DEPTH),.FAST_MULTIPLY(FAST_MULTIPLY),
        .UART_DEFAULT_DIVISOR((CLOCK_HZ+115200*8)/(115200*16))) system_inst (
        .clk(fabric_clk),.rst(rst),.calibrated(cal_sync[1]),
        .uart_tx(cpu_tx),.uart_rx(uart_sync[1]),.boot_done(boot_done),.fault(system_fault),
        .load_req(load_req),.load_finish(load_finish),.load_addr(load_addr),.load_data(load_data),
        .load_ready(load_ready),.load_done(load_done),
        .core_enable(core_enable),.pc_debug(pc_debug),.axi_addr(addr),
        .arvalid(arvalid),.arready(arready),.rvalid(rvalid),.rready(rready),
        .rlast(rlast),.rdata(rdata),.rresp(rresp),.awvalid(awvalid),.awready(awready),
        .wvalid(wvalid),.wready(wready),.wdata(wdata),.wstrb(wstrb),
        .bvalid(bvalid),.bready(bready),.bresp(bresp)
    );
    wire [27:0] m_araddr,m_awaddr;
    wire m_arvalid,m_arready,m_rvalid,m_rready,m_rlast;
    wire m_awvalid,m_awready,m_wvalid,m_wready,m_bvalid,m_bready;
    wire [127:0] m_rdata,m_wdata;
    wire [15:0] m_wstrb;
    wire [1:0] m_rresp,m_bresp;
    generate if(SEPARATE_CPU_CLOCK) begin: clock_crossing
        axi_cpu_cdc converter (
            .s_axi_aclk(fabric_clk),.s_axi_aresetn(!rst),
            .m_axi_aclk(ui_clk),.m_axi_aresetn(axi_reset[1]),
            .s_axi_awid(4'b0),.s_axi_awaddr(addr),.s_axi_awlen(8'b0),
            .s_axi_awsize(3'd4),.s_axi_awburst(2'b01),.s_axi_awlock(1'b0),
            .s_axi_awcache(4'b0),.s_axi_awprot(3'b0),.s_axi_awqos(4'b0),.s_axi_awregion(4'b0),
            .s_axi_awvalid(awvalid),.s_axi_awready(awready),
            .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wlast(1'b1),
            .s_axi_wvalid(wvalid),.s_axi_wready(wready),
            .s_axi_bid(),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
            .s_axi_arid(4'b0),.s_axi_araddr(addr),.s_axi_arlen(8'b0),
            .s_axi_arsize(3'd4),.s_axi_arburst(2'b01),.s_axi_arlock(1'b0),
            .s_axi_arcache(4'b0),.s_axi_arprot(3'b0),.s_axi_arqos(4'b0),.s_axi_arregion(4'b0),
            .s_axi_arvalid(arvalid),.s_axi_arready(arready),
            .s_axi_rid(),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),
            .s_axi_rvalid(rvalid),.s_axi_rready(rready),
            .m_axi_awid(),.m_axi_awaddr(m_awaddr),.m_axi_awlen(),.m_axi_awsize(),
            .m_axi_awburst(),.m_axi_awlock(),.m_axi_awcache(),.m_axi_awprot(),
            .m_axi_awqos(),.m_axi_awregion(),.m_axi_awvalid(m_awvalid),.m_axi_awready(m_awready),
            .m_axi_wdata(m_wdata),.m_axi_wstrb(m_wstrb),.m_axi_wlast(),
            .m_axi_wvalid(m_wvalid),.m_axi_wready(m_wready),
            .m_axi_bid(4'b0),.m_axi_bresp(m_bresp),.m_axi_bvalid(m_bvalid),.m_axi_bready(m_bready),
            .m_axi_arid(),.m_axi_araddr(m_araddr),.m_axi_arlen(),.m_axi_arsize(),
            .m_axi_arburst(),.m_axi_arlock(),.m_axi_arcache(),.m_axi_arprot(),
            .m_axi_arqos(),.m_axi_arregion(),.m_axi_arvalid(m_arvalid),.m_axi_arready(m_arready),
            .m_axi_rid(4'b0),.m_axi_rdata(m_rdata),.m_axi_rresp(m_rresp),.m_axi_rlast(m_rlast),
            .m_axi_rvalid(m_rvalid),.m_axi_rready(m_rready)
        );
    end else begin: common_clock
        assign m_awaddr=addr; assign m_araddr=addr;
        assign m_arvalid=arvalid; assign arready=m_arready;
        assign m_rready=rready; assign rvalid=m_rvalid; assign rlast=m_rlast;
        assign rdata=m_rdata; assign rresp=m_rresp;
        assign m_awvalid=awvalid; assign awready=m_awready;
        assign m_wvalid=wvalid; assign wready=m_wready;
        assign m_wdata=wdata; assign m_wstrb=wstrb;
        assign m_bready=bready; assign bvalid=m_bvalid; assign bresp=m_bresp;
    end endgenerate
    mig_arty mig (
        .sys_clk_i(clk100),.clk_ref_i(clk_ref200),.sys_rst(reset_n),
        .ui_clk(ui_clk),.ui_clk_sync_rst(ui_rst),.aresetn(axi_reset[1]),
        .init_calib_complete(calibrated),
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),.ddr3_we_n(ddr3_we_n),.ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),.ddr3_ck_n(ddr3_ck_n),.ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),.ddr3_dm(ddr3_dm),.ddr3_odt(ddr3_odt),
        .s_axi_awid(4'b0),.s_axi_awaddr(m_awaddr),.s_axi_awlen(8'b0),
        .s_axi_awsize(3'd4),.s_axi_awburst(2'b01),.s_axi_awlock(1'b0),
        .s_axi_awcache(4'b0),.s_axi_awprot(3'b0),.s_axi_awqos(4'b0),
        .s_axi_awvalid(m_awvalid),.s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata),.s_axi_wstrb(m_wstrb),.s_axi_wlast(1'b1),
        .s_axi_wvalid(m_wvalid),.s_axi_wready(m_wready),
        .s_axi_bid(),.s_axi_bresp(m_bresp),.s_axi_bvalid(m_bvalid),.s_axi_bready(m_bready),
        .s_axi_arid(4'b0),.s_axi_araddr(m_araddr),.s_axi_arlen(8'b0),
        .s_axi_arsize(3'd4),.s_axi_arburst(2'b01),.s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0),.s_axi_arprot(3'b0),.s_axi_arqos(4'b0),
        .s_axi_arvalid(m_arvalid),.s_axi_arready(m_arready),
        .s_axi_rid(),.s_axi_rdata(m_rdata),.s_axi_rresp(m_rresp),.s_axi_rlast(m_rlast),
        .s_axi_rvalid(m_rvalid),.s_axi_rready(m_rready),
        .app_sr_req(1'b0),.app_ref_req(1'b0),.app_zq_req(1'b0),
        .app_sr_active(),.app_ref_ack(),.app_zq_ack(),.device_temp()
    );
endmodule
