module complex_mul32_2cycle (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] a_re,
    input  logic [31:0] a_im,
    input  logic [31:0] b_re,
    input  logic [31:0] b_im,
    output logic        valid_out,
    output logic [31:0] result_re,
    output logic [31:0] result_im
);

    // Stage 1: the four crossed products.
    logic [31:0] rr_c, ii_c, ri_c, ir_c;
    logic [31:0] rr_q, ii_q, ri_q, ir_q;
    logic        valid_q;

    // Stage 2: (ar*br - ai*bi) + j(ar*bi + ai*br).
    logic [31:0] result_re_c, result_im_c;

    fp_mul32_lite mul_rr (
        .clk(clk), .rst_n(rst_n), .a_i(a_re), .b_i(b_re), .res_o(rr_c)
    );
    fp_mul32_lite mul_ii (
        .clk(clk), .rst_n(rst_n), .a_i(a_im), .b_i(b_im), .res_o(ii_c)
    );
    fp_mul32_lite mul_ri (
        .clk(clk), .rst_n(rst_n), .a_i(a_re), .b_i(b_im), .res_o(ri_c)
    );
    fp_mul32_lite mul_ir (
        .clk(clk), .rst_n(rst_n), .a_i(a_im), .b_i(b_re), .res_o(ir_c)
    );

    fp_addsub32_lite add_real (
        .clk(clk), .rst_n(rst_n), .a_i(rr_q), .b_i(ii_q),
        .sub_i(1'b1), .res_o(result_re_c)
    );
    fp_addsub32_lite add_imag (
        .clk(clk), .rst_n(rst_n), .a_i(ri_q), .b_i(ir_q),
        .sub_i(1'b0), .res_o(result_im_c)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_q       <= '0;
            ii_q       <= '0;
            ri_q       <= '0;
            ir_q       <= '0;
            result_re  <= '0;
            result_im  <= '0;
            valid_q    <= 1'b0;
            valid_out  <= 1'b0;
        end else begin
            rr_q       <= rr_c;
            ii_q       <= ii_c;
            ri_q       <= ri_c;
            ir_q       <= ir_c;
            result_re  <= result_re_c;
            result_im  <= result_im_c;
            valid_q    <= valid_in;
            valid_out  <= valid_q;
        end
    end

endmodule
