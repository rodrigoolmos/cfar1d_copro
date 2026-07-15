module tb_cfar_1d;
    localparam int MAX_WINDOW_CELLS = 16;
    localparam int MAX_WAIT = 40;

    logic clk, rst_n, reset_window, start, done;
    logic [31:0] alpha;
    logic [31:0] training_cells_left, training_cells_right;
    logic [31:0] guard_cells_left, guard_cells_right;
    logic [31:0] data_in_re, data_in_im;
    logic [7:0] detection_map;

    real model_window [0:MAX_WINDOW_CELLS-1];
    int model_count, window_size, cut_index, checks;
    int tl, tr, gl, gr;
    real alpha_over_n;

    cfar_1d #(.MAX_WINDOW_CELLS(MAX_WINDOW_CELLS)) dut (.*);

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] f32(input shortreal value);
        return $shortrealtobits(value);
    endfunction

    task automatic clear_model();
        model_count = 0;
        for (int i = 0; i < MAX_WINDOW_CELLS; i++) model_window[i] = 0.0;
    endtask

    task automatic configure(
        input shortreal embedded_alpha,
        input int left_training, right_training, left_guard, right_guard
    );
        @(negedge clk);
        alpha = f32(embedded_alpha);
        training_cells_left = left_training;
        training_cells_right = right_training;
        guard_cells_left = left_guard;
        guard_cells_right = right_guard;
        reset_window = 1'b1;
        @(posedge clk);
        #1;
        if (!done || detection_map != 0) $fatal(1, "reset_window incorrecto");
        @(negedge clk);
        reset_window = 1'b0;
        tl = left_training; tr = right_training;
        gl = left_guard; gr = right_guard;
        window_size = tl + tr + gl + gr + 1;
        cut_index = tr + gr;
        alpha_over_n = embedded_alpha;
        clear_model();
    endtask

    task automatic push(input shortreal re, im, input string label);
        real training_sum, expected_threshold, cut_power;
        logic expected;
        int waited;

        if (!done) $fatal(1, "%s: DUT ocupado antes de start", label);
        @(negedge clk);
        data_in_re = f32(re);
        data_in_im = f32(im);
        start = 1'b1;
        @(posedge clk);
        #1;
        if (done) $fatal(1, "%s: no acepto start", label);
        @(negedge clk);
        start = 1'b0;

        for (int i = MAX_WINDOW_CELLS-1; i > 0; i--)
            model_window[i] = model_window[i-1];
        model_window[0] = (re * re) + (im * im);
        if (model_count < window_size) model_count++;

        waited = 0;
        while (!done && waited < MAX_WAIT) begin
            @(posedge clk);
            #1;
            waited++;
        end
        if (!done) $fatal(1, "%s: timeout", label);

        if (model_count >= window_size) begin
            training_sum = 0.0;
            for (int i = 0; i < MAX_WINDOW_CELLS; i++) begin
                if ((i < tr) ||
                    ((i >= tr + gr + 1 + gl) && (i < tr + gr + 1 + gl + tl)))
                    training_sum = training_sum + model_window[i];
            end
            expected_threshold = training_sum * alpha_over_n;
            cut_power = model_window[cut_index];
            expected = cut_power > expected_threshold;
            if (detection_map !== (expected ? 8'd1 : 8'd0))
                $fatal(1, "%s: detection=%0d esperado=%0d cut=%f sum=%f alpha/N=%f threshold=%f",
                       label, detection_map, expected, cut_power, training_sum,
                       alpha_over_n, expected_threshold);
            checks++;
        end
    endtask

    task automatic fill_directed(input shortreal cut_re, cut_im, input string label);
        // Reverse order because the newest sample occupies window[0].
        push(10.0, 0.0, {label, " train left 0"});
        push(10.0, 0.0, {label, " train left 1"});
        push(50.0, 0.0, {label, " guard left"});
        push(cut_re, cut_im, {label, " CUT"});
        push(50.0, 0.0, {label, " guard right"});
        push(10.0, 0.0, {label, " train right 1"});
        push(10.0, 0.0, {label, " train right 0"});
    endtask

    initial begin
        rst_n = 1'b0; reset_window = 1'b0; start = 1'b0;
        alpha = '0; training_cells_left = '0; training_cells_right = '0;
        guard_cells_left = '0; guard_cells_right = '0;
        data_in_re = '0; data_in_im = '0; checks = 0;
        clear_model();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;
        if (!done) $fatal(1, "done no esta alto tras reset");

        // Original alpha=2.0 and four training cells: software supplies 0.5.
        // sum=400, threshold=200. A second /4 in hardware would fail the miss.
        configure(0.5, 2, 2, 1, 1);
        fill_directed(10.0, 0.0, "sin division miss");

        configure(0.5, 2, 2, 1, 1);
        fill_directed(12.0, 16.0, "complejo detect"); // |12+j16|^2 = 400

        // Asymmetric selection and fractional FP32 samples.
        configure(0.25, 3, 1, 0, 2);
        repeat (14) begin
            push(shortreal'(($urandom_range(2, 12)) * 0.5),
                 shortreal'(($urandom_range(0, 6)) * 0.25), "asimetrico");
        end

        if (checks < 4) $fatal(1, "checks insuficientes: %0d", checks);
        $display("All cfar_1d FP32 complex tests passed: checks=%0d", checks);
        $finish;
    end
endmodule
