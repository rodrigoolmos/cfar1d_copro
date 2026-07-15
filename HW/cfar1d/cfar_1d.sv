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
    logic [31:0] training_sum;
    // Kept as training_average for interface/readability continuity. There is
    // no divider: it contains the sum and active_alpha contains alpha/N.
    logic [31:0] training_average;
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

    logic        power_valid_in;
    logic        power_valid_out;
    logic [31:0] input_power;
    logic [31:0] input_power_im;
    logic [31:0] conjugate_im;

    typedef enum logic [2:0] {
        IDLE, POWER_WAIT, SUM_START, SUM_WAIT, DETECTION
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
    assign training_sum_valid_in = (state == SUM_START);
    assign training_tree_rst_n = rst_n & ~reset_window;
    assign power_valid_in = start & (state == IDLE);
    assign conjugate_im = (data_in_im[30:0] == 31'd0) ? 32'd0 :
                          {~data_in_im[31], data_in_im[30:0]};

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
    ) training_sum_tree (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .valid_in(training_sum_valid_in),
        .a(training_inputs),
        .sum(training_sum),
        .valid_out(training_sum_valid_out)
    );

    // active_alpha is alpha/Ntraining, so training_average is intentionally
    // the unnormalised sum and no hardware divider is inferred.
    fp_mul32_lite threshold_mul (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .a_i(training_average),
        .b_i(active_alpha),
        .res_o(threshold)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                         <= IDLE;
            done                          <= 1'b1;
            detection_map                 <= '0;
            window_cnt                    <= '0;
            window                        <= '0;
            training_average              <= '0;
            active_training_cells_left    <= '0;
            active_training_cells_right   <= '0;
            active_guard_cells_left       <= '0;
            active_guard_cells_right      <= '0;
            active_alpha                  <= '0;
            active_cut                    <= '0;
        end else if (reset_window) begin
            state                         <= IDLE;
            done                          <= 1'b1;
            detection_map                 <= '0;
            window_cnt                    <= '0;
            window                        <= '0;
            training_average              <= '0;
            active_training_cells_left    <= '0;
            active_training_cells_right   <= '0;
            active_guard_cells_left       <= '0;
            active_guard_cells_right      <= '0;
            active_alpha                  <= '0;
            active_cut                    <= '0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b1;
                    if (start) begin
                        done  <= 1'b0;
                        state <= POWER_WAIT;
                    end
                end

                POWER_WAIT: begin
                    done <= 1'b0;
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
                            state                       <= SUM_START;
                        end
                    end
                end

                SUM_START: begin
                    done  <= 1'b0;
                    state <= SUM_WAIT;
                end

                SUM_WAIT: begin
                    done <= 1'b0;
                    if (training_sum_valid_out) begin
                        training_average <= training_sum;
                        state            <= DETECTION;
                    end
                end

                DETECTION: begin
                    detection_map <= fp32_gt(window[active_cut], threshold) ? 8'd1 : 8'd0;
                    done          <= 1'b1;
                    state         <= IDLE;
                end

                default: begin
                    state <= IDLE;
                    done  <= 1'b1;
                end
            endcase
        end
    end

endmodule
