`default_nettype none
`include "instr_defines.vh"
module alu (
    input wire [31:0] rs1,
    input wire [31:0] rs2,
    input wire [31:0] imm,
    input wire [ 5:0] instr_id,
    input wire [31:0] pc_input,
    output reg [31:0] ALUoutput
);

wire signed [31:0] rs1_signed = $signed(rs1);
wire signed [31:0] rs2_signed = $signed(rs2);
wire signed [63:0] rs1_signed_ext = {{32{rs1[31]}}, rs1};
wire signed [63:0] rs2_signed_ext = {{32{rs2[31]}}, rs2};
wire [63:0] rs1_unsigned_ext = {32'b0, rs1};
wire [63:0] rs2_unsigned_ext = {32'b0, rs2};
wire signed [63:0] mul_signed = rs1_signed_ext * rs2_signed_ext;
wire signed [63:0] mul_mixed = rs1_signed_ext * $signed(rs2_unsigned_ext);
wire [63:0] mul_unsigned = rs1_unsigned_ext * rs2_unsigned_ext;
wire div_by_zero = (rs2 == 0);
wire div_overflow = (rs1 == 32'h80000000) && (rs2 == 32'hFFFFFFFF);

`ifdef FORMAL
    // Simplified ALU for formal verification - only basic operations
    always @(*) begin
        case (instr_id)
            INSTR_ADD:   ALUoutput = rs1 + rs2;   // Simple addition
            INSTR_SUB:   ALUoutput = rs1 - rs2;   // Simple subtraction
            INSTR_XOR:   ALUoutput = rs1 ^ rs2;   // Bitwise XOR
            INSTR_OR:    ALUoutput = rs1 | rs2;   // Bitwise OR
            INSTR_AND:   ALUoutput = rs1 & rs2;   // Bitwise AND
            INSTR_ADDI:  ALUoutput = rs1 + imm;  // Add immediate
            INSTR_XORI:  ALUoutput = rs1 ^ imm;  // Bitwise XOR with immediate
            INSTR_ORI:   ALUoutput = rs1 | imm;  // Bitwise OR with immediate
            INSTR_ANDI:  ALUoutput = rs1 & imm;  // Bitwise AND with immediate
            default:     ALUoutput = 32'h0;  // Default case: output zero
        endcase
    end
`else
    // Full ALU implementation for synthesis
    always @(*) begin
        case (instr_id)
            INSTR_ADD:   ALUoutput = $signed(rs1) + $signed(rs2);   // Addition
            INSTR_SUB:   ALUoutput = $signed(rs1) - $signed(rs2);   // Subtraction
            INSTR_XOR:   ALUoutput = rs1 ^ rs2;   // Bitwise XOR
            INSTR_OR:    ALUoutput = rs1 | rs2;   // Bitwise OR
            INSTR_AND:   ALUoutput = rs1 & rs2;   // Bitwise AND
            INSTR_SLL:   ALUoutput = rs1 << rs2[4:0];  // Logical left shift
            INSTR_SRL:   ALUoutput = rs1 >> rs2[4:0];  // Logical right shift
            INSTR_SRA:   ALUoutput = $signed(rs1) >>> rs2[4:0];  // Arithmetic right shift
            INSTR_SLT:   ALUoutput = {32{$signed(rs1) < $signed(rs2)}};  // Set less than (signed comparison)
            INSTR_SLTU:  ALUoutput = {32{rs1 < rs2}};  // Set less than (unsigned comparison)
            INSTR_ADDI:  ALUoutput = $signed(rs1) + $signed(imm);  // Add immediate
            INSTR_XORI:  ALUoutput = rs1 ^ imm;  // Bitwise XOR with immediate
            INSTR_ORI:   ALUoutput = rs1 | imm;  // Bitwise OR with immediate
            INSTR_ANDI:  ALUoutput = rs1 & imm;  // Bitwise AND with immediate
            INSTR_SLLI:  ALUoutput = rs1 << imm[4:0];  // Logical left shift with immediate
            INSTR_SRLI:  ALUoutput = rs1 >> imm[4:0];  // Logical right shift with immediate
            INSTR_SRAI:  ALUoutput = $signed(rs1) >>> imm[4:0];  // Arithmetic right shift with immediate
            INSTR_SLTI:  ALUoutput = {32{$signed(rs1) < $signed(imm)}};  // Set less than immediate (signed comparison)
            INSTR_SLTIU: ALUoutput = {32{rs1 < imm}};  // Set less than immediate (unsigned comparison)
            INSTR_MUL:   ALUoutput = mul_signed[31:0];  // Low word of signed multiply
            INSTR_MULH:  ALUoutput = mul_signed[63:32];  // High word of signed multiply
            INSTR_MULHSU: ALUoutput = mul_mixed[63:32];  // High word of signed*unsigned multiply
            INSTR_MULHU: ALUoutput = mul_unsigned[63:32];  // High word of unsigned multiply
            INSTR_DIV: begin
                if (div_by_zero) begin
                    ALUoutput = 32'hFFFFFFFF;
                end else if (div_overflow) begin
                    ALUoutput = 32'h80000000;
                end else begin
                    ALUoutput = rs1_signed / rs2_signed;
                end
            end
            INSTR_DIVU: begin
                if (div_by_zero) begin
                    ALUoutput = 32'hFFFFFFFF;
                end else begin
                    ALUoutput = rs1 / rs2;
                end
            end
            INSTR_REM: begin
                if (div_by_zero) begin
                    ALUoutput = rs1;
                end else if (div_overflow) begin
                    ALUoutput = 32'h00000000;
                end else begin
                    ALUoutput = rs1_signed % rs2_signed;
                end
            end
            INSTR_REMU: begin
                if (div_by_zero) begin
                    ALUoutput = rs1;
                end else begin
                    ALUoutput = rs1 % rs2;
                end
            end
            default:     ALUoutput = 0;  // Default case: output zero
        endcase
    end
`endif
endmodule
