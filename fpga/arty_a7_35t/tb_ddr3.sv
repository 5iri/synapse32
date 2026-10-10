`timescale 1ns/1ps
`default_nettype none
// Full controller/PHY test against the DDR3 component model exported by MIG.
module tb_ddr3;
    reg clk100=0,clk_ref200=0,cpu_clk50=0,reset_n=0;
    always #5 clk100=~clk100;
    always #2.5 clk_ref200=~clk_ref200;
    always #10 cpu_clk50=~cpu_clk50;
    wire [15:0] dq;
    wire [1:0] dqs_n,dqs_p,dm;
    wire [15:0] dq_memory;
    wire [1:0] dqs_n_memory,dqs_p_memory;
    wire [13:0] addr;
    wire [2:0] ba;
    wire ras_n,cas_n,we_n,ddr_reset_n;
    wire [0:0] ck_p,ck_n,cke,cs_n,odt;
    wire uart_tx,calibrated,boot_done,fault;
    wire [31:0] pc;
    arty_ddr3_top #(.SEPARATE_CPU_CLOCK(1),.CLOCK_HZ(50000000)) dut (
        .cpu_clk50(cpu_clk50),.clk100(clk100),.clk_ref200(clk_ref200),.reset_n(reset_n),.uart_rx(1'b1),
        .uart_tx(uart_tx),.calibrated(calibrated),.boot_done(boot_done),.fault(fault),.pc_debug(pc),
        .ddr3_dq(dq),.ddr3_dqs_n(dqs_n),.ddr3_dqs_p(dqs_p),
        .ddr3_addr(addr),.ddr3_ba(ba),.ddr3_ras_n(ras_n),.ddr3_cas_n(cas_n),
        .ddr3_we_n(we_n),.ddr3_reset_n(ddr_reset_n),.ddr3_ck_p(ck_p),.ddr3_ck_n(ck_n),
        .ddr3_cke(cke),.ddr3_cs_n(cs_n),.ddr3_dm(dm),.ddr3_odt(odt)
    );
    ddr3_model memory (
        .rst_n(ddr_reset_n),.ck(ck_p[0]),.ck_n(ck_n[0]),.cke(cke[0]),.cs_n(cs_n[0]),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.dm_tdqs(dm[1:0]),.ba(ba),.addr(addr),
        .dq(dq_memory[15:0]),.dqs(dqs_p_memory[1:0]),.dqs_n(dqs_n_memory[1:0]),.tdqs_n(),.odt(odt[0])
    );
    // Use MIG's bidirectional board-wire model between the PHY and DRAM.
    genvar bit_index;
    generate
        for(bit_index=0;bit_index<16;bit_index=bit_index+1) begin: dq_wires
            WireDelay wire_dq(.A(dq[bit_index]),.B(dq_memory[bit_index]),
                              .reset(reset_n),.phy_init_done(calibrated));
        end
        for(bit_index=0;bit_index<2;bit_index=bit_index+1) begin: dqs_wires
            WireDelay wire_p(.A(dqs_p[bit_index]),.B(dqs_p_memory[bit_index]),
                             .reset(reset_n),.phy_init_done(calibrated));
            WireDelay wire_n(.A(dqs_n[bit_index]),.B(dqs_n_memory[bit_index]),
                             .reset(reset_n),.phy_init_done(calibrated));
        end
    endgenerate
    integer cycles=0;
    reg saw_cal=0,saw_boot=0;
    always @(posedge dut.ui_clk) begin
        cycles<=cycles+1;
        if(calibrated&&!saw_cal) begin
            saw_cal<=1; $display("DDR3 calibration complete at %t",$time);
        end
        if(boot_done&&!saw_boot) begin saw_boot<=1;$display("DDR3 boot image loaded at %t",$time);end
        if(fault) $fatal(1,"AXI error PC=%h",pc);
        if(boot_done && dut.system_inst.cpu.rf_inst0.register_file[31]==32'hdead)
            $fatal(1,"CPU DDR3 smoke failed PC=%h",pc);
        if(boot_done && dut.system_inst.cpu.rf_inst0.register_file[31]==32'h600d) begin
            $display("PASS: Synapse32 Arty A7-35T MIG DDR3 simulation, UI cycles=%0d PC=%h",cycles,pc);
            $finish;
        end
    end
    initial begin
        #100000;reset_n=1;
        #10000000;$fatal(1,"DDR3 timeout calibrated=%b boot=%b PC=%h",calibrated,boot_done,pc);
    end
endmodule
