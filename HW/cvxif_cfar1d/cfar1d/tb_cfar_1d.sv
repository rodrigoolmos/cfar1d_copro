module tb_cfar_1d;

    localparam int MAX_WINDOW_CELLS = 16;
    localparam int MAX_RESULT_WAIT = $clog2(MAX_WINDOW_CELLS) + 8;

    logic        clk;
    logic        rst_n;
    logic        reset_window;
    logic [31:0] alpha;
    logic [31:0] training_cells_left;
    logic [31:0] training_cells_right;
    logic [31:0] guard_cells_left;
    logic [31:0] guard_cells_right;
    logic        start;
    logic        done;
    logic [31:0] data_in;
    logic [7:0]  detection_map;

    logic [31:0] model_window [0:MAX_WINDOW_CELLS-1];
    int unsigned model_count;
    int unsigned cfg_alpha;
    int unsigned cfg_training_left;
    int unsigned cfg_training_right;
    int unsigned cfg_guard_left;
    int unsigned cfg_guard_right;
    int unsigned cfg_window_size;
    int unsigned cfg_training_total;
    int unsigned cfg_cut;
    int unsigned checks_done;
    int unsigned detections_seen;
    int unsigned misses_seen;

    cfar_1d #(
        .MAX_WINDOW_CELLS(MAX_WINDOW_CELLS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .reset_window(reset_window),
        .alpha(alpha),
        .training_cells_left(training_cells_left),
        .training_cells_right(training_cells_right),
        .guard_cells_left(guard_cells_left),
        .guard_cells_right(guard_cells_right),
        .start(start),
        .done(done),
        .data_in(data_in),
        .detection_map(detection_map)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic fail(input string msg);
        $fatal(1, "[%0t] %s", $time, msg);
    endtask

    task automatic clear_model();
        for (int i = 0; i < MAX_WINDOW_CELLS; i++) begin
            model_window[i] = '0;
        end
        model_count = 0;
    endtask

    task automatic model_push(input logic [31:0] sample);
        for (int i = MAX_WINDOW_CELLS - 1; i > 0; i--) begin
            model_window[i] = model_window[i - 1];
        end
        model_window[0] = sample;

        if (model_count < cfg_window_size) begin
            model_count++;
        end
    endtask

    function automatic longint unsigned model_training_sum();
        longint unsigned sum;

        sum = 0;
        for (int i = 0; i < MAX_WINDOW_CELLS; i++) begin
            if ((i < cfg_training_right) ||
                ((i >= cfg_training_right + cfg_guard_right + 1 + cfg_guard_left) &&
                 (i <  cfg_training_right + cfg_guard_right + 1 + cfg_guard_left + cfg_training_left))) begin
                sum += model_window[i];
            end
        end

        return sum;
    endfunction

    task automatic apply_reset();
        rst_n = 1'b0;
        reset_window = 1'b0;
        alpha = '0;
        training_cells_left = '0;
        training_cells_right = '0;
        guard_cells_left = '0;
        guard_cells_right = '0;
        start = 1'b0;
        data_in = '0;
        clear_model();

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        if (done !== 1'b1) begin
            fail("done debe estar alto tras rst_n");
        end
        if (detection_map !== 8'd0) begin
            fail("detection_map debe resetearse a 0 tras rst_n");
        end
    endtask

    task automatic configure(
        input int unsigned alpha_val,
        input int unsigned training_left,
        input int unsigned training_right,
        input int unsigned guard_left,
        input int unsigned guard_right
    );
        int unsigned next_window_size;
        int unsigned next_training_total;

        next_window_size = training_left + training_right + guard_left + guard_right + 1;
        next_training_total = training_left + training_right;

        if (next_window_size > MAX_WINDOW_CELLS) begin
            fail($sformatf("configuracion invalida: window_size=%0d > MAX_WINDOW_CELLS=%0d",
                           next_window_size, MAX_WINDOW_CELLS));
        end
        if (next_training_total == 0) begin
            fail("configuracion invalida: se necesita al menos una celda de entrenamiento");
        end

        @(negedge clk);
        alpha = alpha_val;
        training_cells_left = training_left;
        training_cells_right = training_right;
        guard_cells_left = guard_left;
        guard_cells_right = guard_right;
        start = 1'b0;
        data_in = '0;
        reset_window = 1'b1;

        @(posedge clk);
        #1;
        if (done !== 1'b1) begin
            fail("done debe estar alto durante reset_window");
        end
        if (detection_map !== 8'd0) begin
            fail("detection_map debe resetearse a 0 durante reset_window");
        end

        @(negedge clk);
        reset_window = 1'b0;

        cfg_alpha = alpha_val;
        cfg_training_left = training_left;
        cfg_training_right = training_right;
        cfg_guard_left = guard_left;
        cfg_guard_right = guard_right;
        cfg_window_size = next_window_size;
        cfg_training_total = next_training_total;
        cfg_cut = training_right + guard_right;
        clear_model();
    endtask

    task automatic push_and_check(input logic [31:0] sample, input string label);
        bit expected_detection;
        logic [7:0] expected_map;
        longint unsigned training_sum;
        longint unsigned training_average;
        longint unsigned threshold;
        longint unsigned cut_value;
        int unsigned wait_cycles;
        bit result_valid;

        if (done !== 1'b1) begin
            fail($sformatf("%s: el DUT no estaba listo antes de start", label));
        end

        @(negedge clk);
        data_in = sample;
        start = 1'b1;

        @(posedge clk);
        #1;
        if (done !== 1'b0) begin
            fail($sformatf("%s: done debe bajar cuando se acepta start", label));
        end

        @(negedge clk);
        start = 1'b0;
        model_push(sample);
        result_valid = (model_count >= cfg_window_size);

        @(posedge clk);
        #1;

        if (!result_valid) begin
            if (done !== 1'b1) begin
                fail($sformatf("%s: done debe subir tras precargar una muestra", label));
            end
            return;
        end

        if (done !== 1'b0) begin
            fail($sformatf("%s: done subio demasiado pronto antes de terminar la suma en arbol", label));
        end

        training_sum = model_training_sum();
        training_average = training_sum / cfg_training_total;
        threshold = training_average * cfg_alpha;
        cut_value = model_window[cfg_cut];
        expected_detection = (cut_value > threshold);
        expected_map = expected_detection ? 8'd1 : 8'd0;

        wait_cycles = 0;
        while (done !== 1'b1 && wait_cycles < MAX_RESULT_WAIT) begin
            @(posedge clk);
            #1;
            wait_cycles++;
        end

        if (done !== 1'b1) begin
            fail($sformatf("%s: done no subio con el resultado de deteccion tras %0d ciclos",
                           label, wait_cycles));
        end
        if (detection_map !== expected_map) begin
            fail($sformatf("%s: detection_map=%0d esperado=%0d cut=%0d sum=%0d avg=%0d threshold=%0d",
                           label, detection_map, expected_map, cut_value,
                           training_sum, training_average, threshold));
        end

        checks_done++;
        if (expected_detection) begin
            detections_seen++;
        end else begin
            misses_seen++;
        end
    endtask

    task automatic run_incremental_sequence(
        input string case_name,
        input int unsigned num_samples,
        input int unsigned base,
        input int unsigned step,
        input int unsigned modulo
    );
        logic [31:0] sample;

        $display("[%0t] %s", $time, case_name);
        for (int i = 0; i < num_samples; i++) begin
            sample = 32'((base + (i * step)) % modulo);
            push_and_check(sample, $sformatf("%s sample %0d", case_name, i));
        end
    endtask

    task automatic expect_progress(
        input string case_name,
        input int unsigned start_checks,
        input int unsigned start_detections,
        input int unsigned start_misses,
        input int unsigned min_checks,
        input int unsigned min_detections,
        input int unsigned min_misses
    );
        int unsigned case_checks;
        int unsigned case_detections;
        int unsigned case_misses;

        case_checks = checks_done - start_checks;
        case_detections = detections_seen - start_detections;
        case_misses = misses_seen - start_misses;

        if (case_checks < min_checks) begin
            fail($sformatf("%s: checks=%0d esperado al menos %0d", case_name, case_checks, min_checks));
        end
        if (case_detections < min_detections) begin
            fail($sformatf("%s: detecciones=%0d esperado al menos %0d",
                           case_name, case_detections, min_detections));
        end
        if (case_misses < min_misses) begin
            fail($sformatf("%s: no detecciones=%0d esperado al menos %0d",
                           case_name, case_misses, min_misses));
        end
    endtask

    task automatic pulse_reset_window_midstream();
        @(negedge clk);
        reset_window = 1'b1;
        start = 1'b0;
        data_in = '0;

        @(posedge clk);
        #1;
        if (done !== 1'b1) begin
            fail("reset_window midstream: done debe quedar alto");
        end
        if (detection_map !== 8'd0) begin
            fail("reset_window midstream: detection_map debe quedar en 0");
        end

        @(negedge clk);
        reset_window = 1'b0;
        clear_model();
    endtask

    initial begin
        int unsigned c0;
        int unsigned d0;
        int unsigned m0;

        checks_done = 0;
        detections_seen = 0;
        misses_seen = 0;

        apply_reset();

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(1, 2, 2, 1, 1);
        push_and_check(32'd10,  "symmetric detect preload 0");
        push_and_check(32'd10,  "symmetric detect preload 1");
        push_and_check(32'd50,  "symmetric detect right guard");
        push_and_check(32'd100, "symmetric detect cut");
        push_and_check(32'd50,  "symmetric detect left guard");
        push_and_check(32'd10,  "symmetric detect right training");
        push_and_check(32'd10,  "symmetric detect final");
        push_and_check(32'd10,  "symmetric miss 0");
        push_and_check(32'd10,  "symmetric miss 1");
        push_and_check(32'd10,  "symmetric miss 2");
        expect_progress("symmetric directed", c0, d0, m0, 4, 1, 1);

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(2, 3, 1, 2, 0);
        run_incremental_sequence("asymmetric left-heavy alpha=2", 20, 3, 17, 113);
        expect_progress("asymmetric left-heavy alpha=2", c0, d0, m0, 10, 1, 1);

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(1, 1, 3, 0, 2);
        run_incremental_sequence("asymmetric right-heavy zero-left-guard", 20, 91, 29, 127);
        expect_progress("asymmetric right-heavy zero-left-guard", c0, d0, m0, 10, 1, 1);

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(1, 4, 4, 3, 4);
        run_incremental_sequence("max window size", 24, 7, 23, 251);
        expect_progress("max window size", c0, d0, m0, 8, 1, 1);

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(1, 0, 4, 0, 1);
        run_incremental_sequence("right-training-only", 16, 5, 11, 97);
        expect_progress("right-training-only", c0, d0, m0, 8, 1, 1);

        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        configure(1, 4, 0, 1, 0);
        run_incremental_sequence("left-training-only", 16, 67, 19, 103);
        expect_progress("left-training-only", c0, d0, m0, 8, 1, 1);

        configure(1, 2, 2, 1, 1);
        push_and_check(32'd9,  "reset prefill 0");
        push_and_check(32'd9,  "reset prefill 1");
        push_and_check(32'd99, "reset prefill 2");
        pulse_reset_window_midstream();
        c0 = checks_done;
        d0 = detections_seen;
        m0 = misses_seen;
        push_and_check(32'd5,  "after reset preload 0");
        push_and_check(32'd5,  "after reset preload 1");
        push_and_check(32'd20, "after reset guard 0");
        push_and_check(32'd80, "after reset cut");
        push_and_check(32'd20, "after reset guard 1");
        push_and_check(32'd5,  "after reset training 0");
        push_and_check(32'd5,  "after reset final");
        expect_progress("reset_window midstream", c0, d0, m0, 1, 1, 0);

        $display("All cfar_1d tests passed: checks=%0d detections=%0d misses=%0d",
                 checks_done, detections_seen, misses_seen);
        $finish;
    end

endmodule
