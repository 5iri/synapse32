`timescale 1ns / 1ps

module gpio_tb;

    reg         clk;
    reg         rst;
    reg  [31:0] addr;
    reg  [31:0] write_data;
    reg         write_enable;
    reg         read_enable;
    wire [31:0] read_data;
    wire        gpio_valid;

    reg  [31:0] gpio_in;
    wire [31:0] gpio_out;
    wire [31:0] gpio_oe;

    // DUT
    gpio dut (
        .clk(clk),
        .rst(rst),
        .addr(addr),
        .write_data(write_data),
        .write_enable(write_enable),
        .read_enable(read_enable),
        .read_data(read_data),
        .gpio_valid(gpio_valid),
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_oe(gpio_oe)
    );

    // Clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Simple tasks for bus ops (using absolute addresses from memory_map)
    localparam [31:0] GPIO_DATA = 32'h2000_1000;
    localparam [31:0] GPIO_DIR  = 32'h2000_1004;
    localparam [31:0] GPIO_IN   = 32'h2000_1008;

    task write_reg(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk);
        addr         <= a;
        write_data   <= d;
        write_enable <= 1'b1;
        read_enable  <= 1'b0;
        @(negedge clk);
        write_enable <= 1'b0;
    end
    endtask

    task read_reg(input [31:0] a, output [31:0] d);
    begin
        @(negedge clk);
        addr         <= a;
        write_enable <= 1'b0;
        read_enable  <= 1'b1;
        @(negedge clk);
        d = read_data;
        read_enable  <= 1'b0;
    end
    endtask

    integer i;
    reg [31:0] tmp;

    initial begin
        // Init
        rst          = 1'b1;
        addr         = 32'h0;
        write_data   = 32'h0;
        write_enable = 1'b0;
        read_enable  = 1'b0;
        gpio_in      = 32'h0;

        // Hold reset for a few cycles
        for (i = 0; i < 4; i = i + 1) @(posedge clk);
        rst = 1'b0;

        // 1) After reset, outputs and dir should be 0
        read_reg(GPIO_DATA, tmp);
        if (tmp !== 32'h0) begin
            $display("ERROR: GPIO_DATA after reset = 0x%08x, expected 0", tmp);
            $fatal;
        end
        read_reg(GPIO_DIR, tmp);
        if (tmp !== 32'h0) begin
            $display("ERROR: GPIO_DIR after reset = 0x%08x, expected 0", tmp);
            $fatal;
        end
        $display("PASS: reset state (GPIO_DATA and GPIO_DIR == 0)");

        // 2) Configure bit 0 as output, drive it high
        write_reg(GPIO_DIR, 32'h0000_0001);   // bit 0 output
        write_reg(GPIO_DATA, 32'h0000_0001);  // bit 0 high

        #1;
        if (gpio_oe[0] !== 1'b1) begin
            $display("ERROR: gpio_oe[0] = %b, expected 1", gpio_oe[0]);
            $fatal;
        end
        if (gpio_out[0] !== 1'b1) begin
            $display("ERROR: gpio_out[0] = %b, expected 1", gpio_out[0]);
            $fatal;
        end
        $display("PASS: GPIO[0] configured as output and driven high");

        // 3) Configure bit 1 as input, drive gpio_in[1] and read GPIO_IN
        write_reg(GPIO_DIR, 32'h0000_0001); // bit 0 out, bit 1 in
        gpio_in = 32'h0000_0002; // external signal drives bit 1 high

        read_reg(GPIO_IN, tmp);
        if (tmp[1] !== 1'b1) begin
            $display("ERROR: GPIO_IN[1] = %b, expected 1", tmp[1]);
            $fatal;
        end
        $display("PASS: GPIO[1] configured as input and sampled high");

        $display("GPIO basic functional test PASSED");
        $finish;
    end

endmodule
