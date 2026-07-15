module tb_tree_adder;

    localparam int N = 5;
    localparam int LATENCY = $clog2(N);

    logic clk, rst_n, valid_in, valid_out;
    logic [31:0] a [N-1:0];
    logic [31:0] sum;
    logic [31:0] expected_pipe [0:LATENCY-1];
    logic [LATENCY-1:0] valid_pipe;
    int checks;

    tree_adder #(.N(N), .DATA_WIDTH(32), .SUM_WIDTH(32)) dut (.*);

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] f32(input shortreal value);
        return $shortrealtobits(value);
    endfunction

    function automatic logic [31:0] expected_sum();
        shortreal acc;
        acc = 0.0;
        for (int i = 0; i < N; i++) acc = acc + $bitstoshortreal(a[i]);
        return f32(acc);
    endfunction

    task automatic cycle(input logic send_valid, input string label);
        logic [31:0] accepted;
        accepted = expected_sum();
        valid_in = send_valid;
        @(posedge clk);
        for (int i = LATENCY-1; i > 0; i--) begin
            valid_pipe[i] = valid_pipe[i-1];
            expected_pipe[i] = expected_pipe[i-1];
        end
        valid_pipe[0] = send_valid;
        expected_pipe[0] = accepted;
        #1;
        if (valid_out !== valid_pipe[LATENCY-1])
            $fatal(1, "%s: valid_out incorrecto", label);
        if (valid_out) begin
            checks++;
            if (sum !== expected_pipe[LATENCY-1])
                $fatal(1, "%s: sum=%h esperado=%h", label, sum, expected_pipe[LATENCY-1]);
        end
        @(negedge clk);
    endtask

    task automatic set_values(
        input shortreal x0, x1, x2, x3, x4
    );
        a[0] = f32(x0); a[1] = f32(x1); a[2] = f32(x2);
        a[3] = f32(x3); a[4] = f32(x4);
    endtask

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        valid_pipe = '0;
        checks = 0;
        for (int i = 0; i < N; i++) begin
            a[i] = 32'd0;
            expected_pipe[i % LATENCY] = 32'd0;
        end
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        set_values(1.0, 2.0, 3.0, 4.0, 5.0);
        cycle(1'b1, "enteros");
        set_values(0.5, 1.25, 2.0, 4.0, 8.0);
        cycle(1'b1, "fracciones");
        set_values(0.0, 0.0, 0.0, 0.0, 0.0);
        cycle(1'b0, "burbuja");
        repeat (LATENCY + 1) cycle(1'b0, "drenaje");

        if (checks != 2) $fatal(1, "checks=%0d esperado=2", checks);
        $display("tb_tree_adder FP32 OK: latencia=%0d", LATENCY);
        $finish;
    end
endmodule
