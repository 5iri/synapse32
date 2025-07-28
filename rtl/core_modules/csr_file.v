`default_nettype none
module csr_file (
    input wire clk,
    input wire rst,
    input wire [11:0] csr_addr,
    input wire [31:0] write_data,
    input wire write_enable,
    input wire read_enable,
    output reg [31:0] read_data,
    output wire csr_valid,
    output wire [31:0] mstatus,
    output wire [31:0] mie,
    output wire [31:0] mip,
    output wire [31:0] mtvec,
    output wire [31:0] mepc,

    // Add interrupt handling ports
    input wire interrupt_pending,
    input wire [31:0] interrupt_cause_in,
    input wire [31:0] interrupt_pc_in,
    input wire interrupt_taken,
    input wire mret_instruction,
    input wire ecall_exception,
    input wire ebreak_exception,
    
    // Timer interrupt input
    input wire timer_interrupt,
    input wire software_interrupt,
    input wire external_interrupt
);

    // Common CSR addresses
    localparam CSR_MSTATUS   = 12'h300;
    localparam CSR_MISA      = 12'h301;
    localparam CSR_MIE       = 12'h304;
    localparam CSR_MTVEC     = 12'h305;
    localparam CSR_MSCRATCH  = 12'h340;
    localparam CSR_MEPC      = 12'h341;
    localparam CSR_MCAUSE    = 12'h342;
    localparam CSR_MTVAL     = 12'h343;
    localparam CSR_MIP       = 12'h344;
    localparam CSR_CYCLE     = 12'hC00;
    localparam CSR_CYCLEH    = 12'hC80;

    // CSR registers
    reg [31:0] mstatus_reg;
    reg [31:0] misa;
    reg [31:0] mie_reg;
    reg [31:0] mtvec_reg;
    reg [31:0] mscratch;
    reg [31:0] mepc_reg;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mip_reg;
    reg [63:0] cycle_counter;

    assign mstatus = mstatus_reg;
    assign mie = mie_reg;
    assign mip = mip_reg;
    assign mtvec = mtvec_reg;
    assign mepc = mepc_reg;

    // Check if CSR addresses is valid
    assign csr_valid = (csr_addr == CSR_MSTATUS) || (csr_addr == CSR_MISA) ||
                       (csr_addr == CSR_MIE) || (csr_addr == CSR_MTVEC) ||
                       (csr_addr == CSR_MSCRATCH) || (csr_addr == CSR_MEPC) ||
                       (csr_addr == CSR_MCAUSE) || (csr_addr == CSR_MTVAL) ||
                       (csr_addr == CSR_MIP) || (csr_addr == CSR_CYCLE) ||
                       (csr_addr == CSR_CYCLEH);

    // Initialize CSRs
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mstatus_reg <= 32'h00001800;  // MPP=11 (machine mode)
            misa <= 32'h40000100;     // RV32I base
            mie_reg <= 32'h0;
            mtvec_reg <= 32'h0;
            mscratch <= 32'h0;
            mepc_reg <= 32'h0;
            mcause <= 32'h0;
            mtval <= 32'h0;
            mip_reg <= 32'h0;
            cycle_counter <= 64'h0;
        end else begin
            cycle_counter <= cycle_counter + 1;
            
            // Update MIP based on interrupt inputs
            mip_reg[3] <= software_interrupt;  // MSIP
            mip_reg[7] <= timer_interrupt;     // MTIP
            mip_reg[11] <= external_interrupt; // MEIP
            
            // Handle interrupt entry
            if (interrupt_taken) begin
                mepc_reg <= interrupt_pc_in;        // Save current PC
                mcause <= interrupt_cause_in;   // Save interrupt cause
                mstatus_reg[7] <= mstatus_reg[3];        // Save MIE to MPIE
                mstatus_reg[3] <= 1'b0;              // Disable interrupts
            end
            
            // Handle MRET
            else if (mret_instruction) begin
                mstatus_reg[3] <= mstatus_reg[7];        // Restore MIE from MPIE
                mstatus_reg[7] <= 1'b1;              // Set MPIE to 1
            end
            
            // Handle ECALL exception
            else if (ecall_exception) begin
                mepc_reg <= interrupt_pc_in;         // Save current PC
                mcause <= 32'h0000000B;          // Environment call from M-mode
                mstatus_reg[7] <= mstatus_reg[3];        // Save MIE to MPIE
                mstatus_reg[3] <= 1'b0;              // Disable interrupts
            end
            
            // Handle EBREAK exception
            else if (ebreak_exception) begin
                mepc_reg <= interrupt_pc_in;         // Save current PC
                mcause <= 32'h00000003;          // Breakpoint
                mstatus_reg[7] <= mstatus_reg[3];        // Save MIE to MPIE
                mstatus_reg[3] <= 1'b0;              // Disable interrupts
            end
            
            // Normal CSR writes
            else if (write_enable && csr_valid) begin
                case (csr_addr)
                    CSR_MSTATUS:  mstatus_reg <= write_data;
                    CSR_MIE:      mie_reg <= write_data;
                    CSR_MTVEC:    mtvec_reg <= write_data;
                    CSR_MSCRATCH: mscratch <= write_data;
                    CSR_MEPC:     mepc_reg <= write_data;
                    CSR_MCAUSE:   mcause <= write_data;
                    CSR_MTVAL:    mtval <= write_data;
                    // MIP is updated by hardware, only software bits writable
                    CSR_MIP:      mip_reg <= (mip_reg & 32'h888) | (write_data & 32'h777);
                    default: ;
                endcase
            end
        end
    end

    // Read logic
    always @(*) begin
        if (read_enable && csr_valid) begin
            case (csr_addr)
                CSR_MSTATUS:  read_data = mstatus_reg;
                CSR_MISA:     read_data = misa;
                CSR_MIE:      read_data = mie_reg;
                CSR_MTVEC:    read_data = mtvec_reg;
                CSR_MSCRATCH: read_data = mscratch;
                CSR_MEPC:     read_data = mepc_reg;
                CSR_MCAUSE:   read_data = mcause;
                CSR_MTVAL:    read_data = mtval;
                CSR_MIP:      read_data = mip_reg;
                CSR_CYCLE:    read_data = cycle_counter[31:0];
                CSR_CYCLEH:   read_data = cycle_counter[63:32];
                default:      read_data = 32'h0;
            endcase
        end else begin
            read_data = 32'h0;
        end
    end

endmodule