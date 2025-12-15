`default_nettype none
`include "memory_map.vh"

module gpio (
    input  wire        clk,
    input  wire        rst,

    // Memory interface
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        write_enable,
    input  wire        read_enable,
    output reg  [31:0] read_data,
    output wire        gpio_valid,

    // External GPIO pins
    input  wire [31:0] gpio_in,
    output wire [31:0] gpio_out,
    output wire [31:0] gpio_oe
);

    // Simple 32-bit GPIO:
    // - GPIO_DATA: read/write output value
    // - GPIO_DIR:  1 = output, 0 = input
    // - GPIO_IN:   read-only, sampled from gpio_in

    reg [31:0] data_reg;
    reg [31:0] dir_reg;

    // Address decode within GPIO region
    assign gpio_valid = (addr == `GPIO_DATA) ||
                        (addr == `GPIO_DIR)  ||
                        (addr == `GPIO_IN);

    // Drive outputs
    assign gpio_out = data_reg;
    assign gpio_oe  = dir_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_reg <= 32'h0;
            dir_reg  <= 32'h0;
        end else if (write_enable && gpio_valid) begin
            case (addr)
                `GPIO_DATA: data_reg <= write_data;
                `GPIO_DIR:  dir_reg  <= write_data;
                default: ;
            endcase
        end
    end

    always @(*) begin
        if (read_enable && gpio_valid) begin
            case (addr)
                `GPIO_DATA: read_data = data_reg;
                `GPIO_DIR:  read_data = dir_reg;
                `GPIO_IN:   read_data = gpio_in;
                default:    read_data = 32'h0;
            endcase
        end else begin
            read_data = 32'h0;
        end
    end

endmodule

