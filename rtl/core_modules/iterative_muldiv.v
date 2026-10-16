`default_nettype none
`include "instr_defines.vh"
// RV32M divider in 32 iterations. Optional registered DSP multiplication keeps
// the divider iterative while shortening multiply to two busy cycles. Result
// stays valid until consumed, including while an older memory access holds EX.
module iterative_muldiv #(parameter FAST_MULTIPLY = 0) (
    input wire clk, rst, cancel, start, consume,
    input wire [6:0] instr_id,
    input wire [31:0] lhs, rhs,
    output reg busy, done,
    output reg [31:0] result
);
    reg [5:0] count;
    reg division, high_half, remainder_result, negative, remainder_negative;
    reg [63:0] product, multiplicand;
    reg [31:0] multiplier, quotient, divisor;
    reg [32:0] remainder;
    reg signed [32:0] fast_lhs, fast_rhs;
    (* use_dsp = "yes" *) reg signed [65:0] fast_product;
    wire signed_lhs=(instr_id==INSTR_MULH)||(instr_id==INSTR_MULHSU)||
                    (instr_id==INSTR_DIV)||(instr_id==INSTR_REM);
    wire signed_rhs=(instr_id==INSTR_MULH)||(instr_id==INSTR_DIV)||(instr_id==INSTR_REM);
    wire [31:0] lhs_abs=(signed_lhs&&lhs[31]) ? (~lhs+1'b1) : lhs;
    wire [31:0] rhs_abs=(signed_rhs&&rhs[31]) ? (~rhs+1'b1) : rhs;
    wire [63:0] product_next=product+(multiplier[0] ? multiplicand : 64'b0);
    wire [63:0] signed_product=negative ? (~product_next+1'b1) : product_next;
    wire [32:0] shifted_remainder={remainder[31:0],quotient[31]};
    wire subtract=shifted_remainder>={1'b0,divisor};
    wire [32:0] remainder_next=subtract ? shifted_remainder-{1'b0,divisor} : shifted_remainder;
    wire [31:0] quotient_next={quotient[30:0],subtract};
    wire [31:0] signed_quotient=negative ? (~quotient_next+1'b1) : quotient_next;
    wire [31:0] signed_remainder=remainder_negative ? (~remainder_next[31:0]+1'b1) : remainder_next[31:0];
    always @(posedge clk) begin
        if(rst||cancel) begin
            busy<=0; done<=0; result<=0; count<=0; division<=0;
            high_half<=0; remainder_result<=0; negative<=0; remainder_negative<=0;
            product<=0; multiplicand<=0; multiplier<=0; quotient<=0; divisor<=0; remainder<=0;
            fast_lhs<=0; fast_rhs<=0; fast_product<=0;
        end else if(consume) done<=0;
        else if(start&&!busy&&!done) begin
            division<=(instr_id==INSTR_DIV)||(instr_id==INSTR_DIVU)||
                       (instr_id==INSTR_REM)||(instr_id==INSTR_REMU);
            high_half<=(instr_id!=INSTR_MUL);
            remainder_result<=(instr_id==INSTR_REM)||(instr_id==INSTR_REMU);
            negative<=(signed_lhs&&lhs[31])^(signed_rhs&&rhs[31]);
            remainder_negative<=signed_lhs&&lhs[31];
            product<=0; multiplicand<={32'b0,lhs_abs}; multiplier<=rhs_abs;
            quotient<=lhs_abs; divisor<=rhs_abs; remainder<=0; count<=0;
            fast_lhs<=$signed({signed_lhs&&lhs[31],lhs});
            fast_rhs<=$signed({signed_rhs&&rhs[31],rhs});
            if(rhs==0 && ((instr_id==INSTR_DIV)||(instr_id==INSTR_DIVU)||
                          (instr_id==INSTR_REM)||(instr_id==INSTR_REMU))) begin
                result<=((instr_id==INSTR_REM)||(instr_id==INSTR_REMU)) ? lhs : 32'hffffffff;
                done<=1;
            end else busy<=1;
        end else if(busy && FAST_MULTIPLY && !division) begin
            if(count==0) begin
                fast_product<=fast_lhs*fast_rhs;
                count<=1;
            end else begin
                result<=high_half ? fast_product[63:32] : fast_product[31:0];
                busy<=0; done<=1;
            end
        end else if(busy) begin
            count<=count+1'b1;
            if(division) begin quotient<=quotient_next; remainder<=remainder_next; end
            else begin product<=product_next; multiplicand<=multiplicand<<1; multiplier<=multiplier>>1; end
            if(count==31) begin
                busy<=0; done<=1;
                result<=division ? (remainder_result ? signed_remainder : signed_quotient) :
                                   (high_half ? signed_product[63:32] : signed_product[31:0]);
            end
        end
    end
endmodule
