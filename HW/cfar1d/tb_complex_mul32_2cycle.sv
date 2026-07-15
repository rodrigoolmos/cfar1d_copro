module tb_complex_mul32_2cycle;
    logic clk, rst_n, valid_in, valid_out;
    logic [31:0] a_re, a_im, b_re, b_im, result_re, result_im;

    complex_mul32_2cycle dut (.*);

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] f32(input shortreal value);
        return $shortrealtobits(value);
    endfunction

    task automatic launch(
        input shortreal ar, ai, br, bi,
        input shortreal expected_re, expected_im,
        input string label
    );
        @(negedge clk);
        a_re = f32(ar); a_im = f32(ai);
        b_re = f32(br); b_im = f32(bi);
        valid_in = 1'b1;
        @(posedge clk);
        #1;
        if (valid_out) $fatal(1, "%s: valid_out antes de dos etapas", label);
        @(negedge clk);
        valid_in = 1'b0;
        @(posedge clk);
        #1;
        if (!valid_out) $fatal(1, "%s: falta valid_out", label);
        if ((result_re !== f32(expected_re)) || (result_im !== f32(expected_im)))
            $fatal(1, "%s: resultado=(%h,%h), esperado=(%h,%h)",
                   label, result_re, result_im, f32(expected_re), f32(expected_im));
    endtask

    initial begin
        rst_n = 1'b0; valid_in = 1'b0;
        a_re = '0; a_im = '0; b_re = '0; b_im = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        launch(3.0, 4.0, 2.0, -1.0, 10.0, 5.0, "producto complejo");
        launch(3.0, 4.0, 3.0, -4.0, 25.0, 0.0, "potencia x*conj(x)");
        $display("tb_complex_mul32_2cycle OK");
        $finish;
    end
endmodule
