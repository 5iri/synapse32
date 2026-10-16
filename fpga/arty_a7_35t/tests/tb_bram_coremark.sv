`timescale 1ns/1ps
`ifndef BRAM_BOOT_FILE
`define BRAM_BOOT_FILE "coremark_bram.mem"
`endif
module tb_bram_coremark;
    reg clk=0,rst=1,rx=1;
    always #10 clk=~clk;
    wire tx,fault;
    bram_coremark_system #(.CLOCK_HZ(1000000),.MEM_FILE(`BRAM_BOOT_FILE)) dut (
        .clk(clk),.rst(rst),.uart_rx(rx),.uart_tx(tx),.fault(fault),
        .uart_seen(),.pc_debug());
    integer cycles=0,done_count=0,valid_count=0,ready_count=0;
    event ready;
    initial begin repeat(8) @(negedge clk);rst=0; end
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(fault) $fatal(1,"BRAM address range fault at PC %h",dut.pc_debug);
        if(cycles>250000000) $fatal(1,"BRAM CoreMark watchdog expired");
    end
    task send_byte(input byte b);
        @(negedge clk);rx=0;repeat(16) @(negedge clk);
        for(integer bitno=0;bitno<8;bitno=bitno+1) begin
            rx=b[bitno];repeat(16) @(negedge clk);
        end
        rx=1;repeat(32) @(negedge clk);
    endtask
    task send_line(input string command);
        for(integer j=0;j<command.len();j=j+1) send_byte(command[j]);
    endtask
    initial begin
        forever begin
            @ready;
            if(ready_count==1) send_line("p 50\n");
            else if(ready_count==2) send_line("v 50\n");
        end
    end
    byte c;
    string line="";
    integer rc;
    initial begin
        forever begin
            @(negedge tx);
            repeat(24) @(negedge clk);
            for(integer bitno=0;bitno<8;bitno=bitno+1) begin
                c[bitno]=tx;repeat(16) @(negedge clk);
            end
            if(!tx) $fatal(1,"UART stop bit missing");
            if(c==10) begin
                $display("%s",line);
                if(line=="S32_BAREMETAL_READY") begin ready_count=ready_count+1;->ready; end
                if(line.len()>=28&&line.substr(0,27)=="Correct operation validated.") valid_count=valid_count+1;
                if(line.len()>=5&&line.substr(0,4)=="ERROR") $fatal(1,"CoreMark error: %s",line);
                if($sscanf(line,"S32_BAREMETAL_DONE:%d",rc)==1) begin
                    if(rc!=0) $fatal(1,"CoreMark exit %0d",rc);
                    done_count=done_count+1;
                    if(done_count==2) begin
                        if(valid_count!=2) $fatal(1,"Missing CRC validation");
                        $display("BRAM_COREMARK_PASS cycles=%0d csr_cycles=%0d instret=%0d",cycles,
                            dut.cpu.csr_file_inst.cycle_counter,dut.cpu.csr_file_inst.instret_counter);
                        $finish;
                    end
                end
                line="";
            end else if(c!=13) line={line,c};
        end
    end
endmodule
