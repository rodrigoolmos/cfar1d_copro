module cfar_1d #(
    parameter MAX_WINDOW_CELLS = 64
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        reset_window,

    // IEEE-754 FP32. alpha must already include 1/Ntraining.
    input  logic [31:0] alpha,
    input  logic [31:0] training_cells_left,
    input  logic [31:0] training_cells_right,
    input  logic [31:0] guard_cells_left,
    input  logic [31:0] guard_cells_right,

    input  logic        start,
    output logic        done,

    // One FP32 real component and one FP32 imaginary component.
    input  logic [31:0] data_in_re,
    input  logic [31:0] data_in_im,
    output logic [7:0]  detection_map
);

    localparam int WINDOW_COUNT_WIDTH = $clog2(MAX_WINDOW_CELLS + 1);

    logic [WINDOW_COUNT_WIDTH-1:0] window_cnt;
    logic [WINDOW_COUNT_WIDTH-1:0] window_size;
    logic [WINDOW_COUNT_WIDTH-1:0] cut;
    logic [MAX_WINDOW_CELLS-1:0][31:0] window;

    logic [31:0] training_inputs [MAX_WINDOW_CELLS-1:0];
    logic [31:0] training_sum_tree;
    logic [31:0] training_sum_q;
    logic [31:0] threshold;
    logic        training_sum_valid_in;
    logic        training_sum_valid_out;
    logic        training_tree_rst_n;

    logic [31:0] active_training_cells_left;
    logic [31:0] active_training_cells_right;
    logic [31:0] active_guard_cells_left;
    logic [31:0] active_guard_cells_right;
    logic [31:0] active_alpha;
    logic [WINDOW_COUNT_WIDTH-1:0] active_cut;

    logic [WINDOW_COUNT_WIDTH-1:0] left_begin;
    logic [31:0] right_entering;
    logic [31:0] right_leaving;
    logic [31:0] left_entering;
    logic [31:0] left_leaving;
    logic [31:0] right_delta;
    logic [31:0] left_delta;
    logic [31:0] right_delta_q;
    logic [31:0] left_delta_q;
    logic [31:0] delta_total;
    logic [31:0] delta_total_q;
    logic [31:0] updated_training_sum;
    logic        training_sum_initialized;

    logic        power_valid_in;
    logic        power_valid_out;
    logic [31:0] input_power;
    logic [31:0] input_power_im;
    logic [31:0] conjugate_im;

    typedef enum logic [2:0] {
        IDLE, POWER_WAIT, REBASE_START, REBASE_WAIT,
        DELTA_SUM, SUM_UPDATE, DETECTION
    } state_t;
    state_t state;

    function automatic logic fp32_gt(input logic [31:0] a, input logic [31:0] b);
        logic a_zero, b_zero;
        begin
            a_zero = (a[30:0] == 31'd0);
            b_zero = (b[30:0] == 31'd0);
            if (a_zero && b_zero) begin
                fp32_gt = 1'b0;
            end else if (a[31] != b[31]) begin
                fp32_gt = b[31];
            end else if (!a[31]) begin
                fp32_gt = (a[30:0] > b[30:0]);
            end else begin
                fp32_gt = (a[30:0] < b[30:0]);
            end
        end
    endfunction

    assign window_size = training_cells_left + training_cells_right +
                         guard_cells_left + guard_cells_right + 1;
    assign cut = training_cells_right + guard_cells_right;
    assign left_begin = training_cells_right + guard_cells_right + 1 +
                        guard_cells_left;
    assign training_sum_valid_in = (state == REBASE_START);
    assign training_tree_rst_n = rst_n & ~reset_window;
    assign power_valid_in = start & (state == IDLE);
    assign conjugate_im = (data_in_im[30:0] == 31'd0) ? 32'd0 :
                          {~data_in_im[31], data_in_im[30:0]};

    // Sliding-window deltas are formed from the old window while input_power
    // is the sample that will become window[0].  Both training regions are
    // updated in parallel and then folded into training_sum_q in two short
    // registered stages.
    always_comb begin
        right_entering = 32'd0;
        right_leaving  = 32'd0;
        left_entering  = 32'd0;
        left_leaving   = 32'd0;

        if (training_cells_right != 0) begin
            right_entering = input_power;
            right_leaving = window[training_cells_right - 1];
        end
        if (training_cells_left != 0) begin
            left_entering = window[left_begin - 1];
            left_leaving = window[window_size - 1];
        end
    end

    fp_addsub32_lite right_delta_add (
        .clk(clk), .rst_n(training_tree_rst_n),
        .a_i(right_entering), .b_i(right_leaving), .sub_i(1'b1),
        .res_o(right_delta)
    );

    fp_addsub32_lite left_delta_add (
        .clk(clk), .rst_n(training_tree_rst_n),
        .a_i(left_entering), .b_i(left_leaving), .sub_i(1'b1),
        .res_o(left_delta)
    );

    fp_addsub32_lite delta_total_add (
        .clk(clk), .rst_n(training_tree_rst_n),
        .a_i(right_delta_q), .b_i(left_delta_q), .sub_i(1'b0),
        .res_o(delta_total)
    );

    fp_addsub32_lite training_sum_update_add (
        .clk(clk), .rst_n(training_tree_rst_n),
        .a_i(training_sum_q), .b_i(delta_total_q), .sub_i(1'b0),
        .res_o(updated_training_sum)
    );

    // x * conj(x) = (re^2 + im^2) + j0. The generic complex multiplier is
    // explicitly split into the requested product and add/subtract stages.
    complex_mul32_2cycle input_power_mul (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .valid_in(power_valid_in),
        .a_re(data_in_re),
        .a_im(data_in_im),
        .b_re(data_in_re),
        .b_im(conjugate_im),
        .valid_out(power_valid_out),
        .result_re(input_power),
        .result_im(input_power_im)
    );

    always_comb begin
        for (int i = 0; i < MAX_WINDOW_CELLS; ++i) begin
            training_inputs[i] = 32'd0;
            if ((i < active_training_cells_right) ||
                ((i >= active_training_cells_right + active_guard_cells_right + 1 + active_guard_cells_left) &&
                 (i <  active_training_cells_right + active_guard_cells_right + 1 + active_guard_cells_left + active_training_cells_left))) begin
                training_inputs[i] = window[i];
            end
        end
    end

    tree_adder #(
        .N(MAX_WINDOW_CELLS),
        .DATA_WIDTH(32),
        .SUM_WIDTH(32)
    ) training_sum_tree_i (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .valid_in(training_sum_valid_in),
        .a(training_inputs),
        .sum(training_sum_tree),
        .valid_out(training_sum_valid_out)
    );

    // active_alpha is alpha/Ntraining; no divider is inferred in hardware.
    fp_mul32_lite threshold_mul (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .a_i(training_sum_q),
        .b_i(active_alpha),
        .res_o(threshold)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                         <= IDLE;
            done                          <= 1'b0;
            detection_map                 <= '0;
            window_cnt                    <= '0;
            window                        <= '0;
            training_sum_q                 <= '0;
            right_delta_q                  <= '0;
            left_delta_q                   <= '0;
            delta_total_q                  <= '0;
            training_sum_initialized       <= 1'b0;
            active_training_cells_left    <= '0;
            active_training_cells_right   <= '0;
            active_guard_cells_left       <= '0;
            active_guard_cells_right      <= '0;
            active_alpha                  <= '0;
            active_cut                    <= '0;
        end else if (reset_window) begin
            state                         <= IDLE;
            done                          <= 1'b0;
            detection_map                 <= '0;
            window_cnt                    <= '0;
            window                        <= '0;
            training_sum_q                 <= '0;
            right_delta_q                  <= '0;
            left_delta_q                   <= '0;
            delta_total_q                  <= '0;
            training_sum_initialized       <= 1'b0;
            active_training_cells_left    <= '0;
            active_training_cells_right   <= '0;
            active_guard_cells_left       <= '0;
            active_guard_cells_right      <= '0;
            active_alpha                  <= '0;
            active_cut                    <= '0;
        end else begin
            // Completion is a pulse, not an idle level.  The CV-X-IF wrapper
            // consumes it directly without another edge detector/register.
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) state <= POWER_WAIT;
                end

                POWER_WAIT: begin
                    if (power_valid_out) begin
                        window <= {window[MAX_WINDOW_CELLS-2:0], input_power};
                        if (window_cnt + 1 < window_size) begin
                            window_cnt <= window_cnt + 1'b1;
                            done       <= 1'b1;
                            state      <= IDLE;
                        end else begin
                            active_training_cells_left  <= training_cells_left;
                            active_training_cells_right <= training_cells_right;
                            active_guard_cells_left     <= guard_cells_left;
                            active_guard_cells_right    <= guard_cells_right;
                            active_alpha                <= alpha;
                            active_cut                  <= cut;
                            window_cnt                  <= window_size;

                            if (!training_sum_initialized) begin
                                // Seed the accumulator once from the full
                                // reduction; subsequent samples are O(1).
                                state <= REBASE_START;
                            end else begin
                                right_delta_q <= right_delta;
                                left_delta_q  <= left_delta;
                                state         <= DELTA_SUM;
                            end
                        end
                    end
                end

                REBASE_START: begin
                    state <= REBASE_WAIT;
                end

                REBASE_WAIT: begin
                    if (training_sum_valid_out) begin
                        training_sum_q           <= training_sum_tree;
                        training_sum_initialized <= 1'b1;
                        state                    <= DETECTION;
                    end
                end

                DELTA_SUM: begin
                    delta_total_q <= delta_total;
                    state         <= SUM_UPDATE;
                end

                SUM_UPDATE: begin
                    training_sum_q <= updated_training_sum;
                    state          <= DETECTION;
                end

                DETECTION: begin
                    detection_map <= fp32_gt(window[active_cut], threshold) ? 8'd1 : 8'd0;
                    done          <= 1'b1;
                    state         <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
