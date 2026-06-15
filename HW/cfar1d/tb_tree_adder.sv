module tb_tree_adder;

    localparam int N = 5;
    localparam int DATA_WIDTH = 8;
    localparam int SUM_WIDTH = DATA_WIDTH + $clog2(N);
    localparam int LATENCY = $clog2(N);

    logic clk;
    logic rst_n;
    logic valid_in;
    logic [DATA_WIDTH-1:0] a [N-1:0];
    logic [SUM_WIDTH-1:0] sum;
    logic valid_out;

    logic [SUM_WIDTH-1:0] expected_sum_pipe [0:LATENCY-1];
    logic [LATENCY-1:0] expected_valid_pipe;
    int unsigned valid_checks;

    tree_adder #(
        .N(N),
        .DATA_WIDTH(DATA_WIDTH),
        .SUM_WIDTH(SUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .a(a),
        .sum(sum),
        .valid_out(valid_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic fail(input string msg);
        $fatal(1, "[%0t] %s", $time, msg);
    endtask

    function automatic logic [SUM_WIDTH-1:0] model_sum();
        logic [SUM_WIDTH-1:0] acc;

        acc = '0;
        for (int i = 0; i < N; i++) begin
            acc += SUM_WIDTH'(a[i]);
        end

        return acc;
    endfunction

    task automatic clear_expected();
        expected_valid_pipe = '0;
        for (int i = 0; i < LATENCY; i++) begin
            expected_sum_pipe[i] = '0;
        end
    endtask

    task automatic tick_and_check(input string label);
        logic accepted_valid;
        logic [SUM_WIDTH-1:0] accepted_sum;

        accepted_valid = valid_in;
        accepted_sum = model_sum();

        @(posedge clk);
        for (int i = LATENCY - 1; i > 0; i--) begin
            expected_valid_pipe[i] = expected_valid_pipe[i - 1];
            expected_sum_pipe[i] = expected_sum_pipe[i - 1];
        end
        expected_valid_pipe[0] = accepted_valid;
        expected_sum_pipe[0] = accepted_sum;

        #1;
        if (valid_out !== expected_valid_pipe[LATENCY - 1]) begin
            fail($sformatf("%s: valid_out=%0b esperado=%0b",
                           label, valid_out, expected_valid_pipe[LATENCY - 1]));
        end

        if (expected_valid_pipe[LATENCY - 1]) begin
            valid_checks++;
            if (sum !== expected_sum_pipe[LATENCY - 1]) begin
                fail($sformatf("%s: sum=%0d esperado=%0d",
                               label, sum, expected_sum_pipe[LATENCY - 1]));
            end
        end
    endtask

    task automatic apply_vector(
        input logic valid,
        input int unsigned v0,
        input int unsigned v1,
        input int unsigned v2,
        input int unsigned v3,
        input int unsigned v4,
        input string label
    );
        @(negedge clk);
        valid_in = valid;
        a[0] = DATA_WIDTH'(v0);
        a[1] = DATA_WIDTH'(v1);
        a[2] = DATA_WIDTH'(v2);
        a[3] = DATA_WIDTH'(v3);
        a[4] = DATA_WIDTH'(v4);
        tick_and_check(label);
    endtask

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        valid_checks = 0;
        clear_expected();
        for (int i = 0; i < N; i++) begin
            a[i] = '0;
        end

        repeat (3) @(posedge clk);
        #1;
        if (valid_out !== 1'b0) begin
            fail("valid_out debe estar en 0 tras reset");
        end
        if (sum !== '0) begin
            fail("sum debe estar en 0 tras reset");
        end

        rst_n = 1'b1;

        apply_vector(1'b1, 1,   2,  3,  4,  5, "vector 0");
        apply_vector(1'b1, 10, 20, 30, 40, 50, "vector 1");
        apply_vector(1'b0, 9,   9,  9,  9,  9, "burbuja invalida");
        apply_vector(1'b1, 255, 1,  2,  3,  4, "vector 2");
        apply_vector(1'b1, 0,   0,  0,  0,  0, "vector 3");

        for (int i = 0; i < LATENCY + 2; i++) begin
            apply_vector(1'b0, 0, 0, 0, 0, 0, $sformatf("drenaje %0d", i));
        end

        if (valid_checks != 4) begin
            fail($sformatf("se comprobaron %0d resultados validos, esperado=4", valid_checks));
        end

        $display("[%0t] tb_tree_adder OK: latencia=%0d ciclos, resultados validos=%0d",
                 $time, LATENCY, valid_checks);
        $finish;
    end

endmodule
