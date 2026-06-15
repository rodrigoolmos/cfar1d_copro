module cfar_1d #(
    parameter MAX_WINDOW_CELLS = 64
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         reset_window,

    input  logic [31:0]  alpha,
    input  logic [31:0]  training_cells_left,
    input  logic [31:0]  training_cells_right,
    input  logic [31:0]  guard_cells_left,
    input  logic [31:0]  guard_cells_right,

    input  logic         start,
    output logic         done,

    input  logic signed [31:0] data_in_re,
    input  logic signed [31:0] data_in_im,
    output logic [7:0]  detection_map
);

    localparam int WINDOW_COUNT_WIDTH = $clog2(MAX_WINDOW_CELLS + 1);
    localparam int POWER_WIDTH = 64;
    localparam int TRAINING_SUM_WIDTH = POWER_WIDTH + ((MAX_WINDOW_CELLS <= 1) ? 0 : $clog2(MAX_WINDOW_CELLS));
    localparam int THRESHOLD_WIDTH = TRAINING_SUM_WIDTH + 32;

    logic [WINDOW_COUNT_WIDTH-1:0] window_cnt;
    logic [WINDOW_COUNT_WIDTH-1:0] window_size;
    logic [WINDOW_COUNT_WIDTH-1:0] cut;
    logic [MAX_WINDOW_CELLS-1:0][POWER_WIDTH-1:0] window;
    logic [TRAINING_SUM_WIDTH-1:0] training_inputs [MAX_WINDOW_CELLS-1:0];
    logic [TRAINING_SUM_WIDTH-1:0] training_sum;
    logic [TRAINING_SUM_WIDTH-1:0] training_average;
    logic [THRESHOLD_WIDTH-1:0] threshold;
    logic training_sum_valid_in;
    logic training_sum_valid_out;
    logic training_tree_rst_n;
    logic [31:0] active_training_cells_left;
    logic [31:0] active_training_cells_right;
    logic [31:0] active_guard_cells_left;
    logic [31:0] active_guard_cells_right;
    logic [31:0] active_training_cell_count;
    logic [31:0] active_alpha;
    logic [WINDOW_COUNT_WIDTH-1:0] active_cut;

    // Capture input power on start because STORING consumes it one cycle later.
    logic [POWER_WIDTH-1:0] sampled_power;
    logic [POWER_WIDTH-1:0] input_power;

    typedef enum logic [2:0] { IDLE, STORING, SUM_START, SUM_WAIT, DETECTION } state_t;
    state_t state;

    function automatic logic [POWER_WIDTH-1:0] square_signed_32(input logic signed [31:0] value);
        logic signed [65:0] value_ext;
        logic signed [65:0] product;
        begin
            value_ext = value;
            product = value_ext * value_ext;
            square_signed_32 = product[POWER_WIDTH-1:0];
        end
    endfunction

    function automatic logic [POWER_WIDTH-1:0] complex_power(
        input logic signed [31:0] re,
        input logic signed [31:0] im
    );
        begin
            complex_power = square_signed_32(re) + square_signed_32(im);
        end
    endfunction

    assign window_size = training_cells_left + training_cells_right + 
                            guard_cells_left + guard_cells_right + 1;

    assign cut = training_cells_right + guard_cells_right;
    assign training_sum_valid_in = (state == SUM_START);
    assign training_tree_rst_n = rst_n & ~reset_window;
    assign threshold = THRESHOLD_WIDTH'(training_average) * THRESHOLD_WIDTH'(active_alpha);
    assign input_power = complex_power(data_in_re, data_in_im);

    always_comb begin
        for (int i=0; i<MAX_WINDOW_CELLS; ++i) begin
            training_inputs[i] = '0;
            if ((i < active_training_cells_right) ||
                ((i >= active_training_cells_right + active_guard_cells_right + 1 + active_guard_cells_left) &&
                 (i <  active_training_cells_right + active_guard_cells_right + 1 + active_guard_cells_left + active_training_cells_left))) begin
                training_inputs[i] = TRAINING_SUM_WIDTH'(window[i]);
            end
        end
    end

    tree_adder #(
        .N(MAX_WINDOW_CELLS),
        .DATA_WIDTH(TRAINING_SUM_WIDTH),
        .SUM_WIDTH(TRAINING_SUM_WIDTH)
    ) training_sum_tree (
        .clk(clk),
        .rst_n(training_tree_rst_n),
        .valid_in(training_sum_valid_in),
        .a(training_inputs),
        .sum(training_sum),
        .valid_out(training_sum_valid_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1;
            detection_map <= 0;
            window_cnt <= 0;
            training_average <= 0;
            window <= 0;
            active_training_cells_left <= 0;
            active_training_cells_right <= 0;
            active_guard_cells_left <= 0;
            active_guard_cells_right <= 0;
            active_training_cell_count <= 0;
            active_alpha <= 0;
            active_cut <= 0;
            sampled_power <= 0;
        end else if (reset_window) begin
            state <= IDLE;
            done <= 1;
            detection_map <= 0;
            window_cnt <= 0;
            training_average <= 0;
            window <= 0;
            active_training_cells_left <= 0;
            active_training_cells_right <= 0;
            active_guard_cells_left <= 0;
            active_guard_cells_right <= 0;
            active_training_cell_count <= 0;
            active_alpha <= 0;
            active_cut <= 0;
            sampled_power <= 0;
        end else begin
            case (state)

                IDLE: begin
                    done <= 1;
                    if (start) begin
                        sampled_power <= input_power;
                        state <= STORING;
                        done <= 0;
                    end
                end

                STORING: begin
                    if (window_cnt + 1 < window_size) begin
                        window <= {window[MAX_WINDOW_CELLS-2:0], sampled_power};
                        window_cnt <= window_cnt + 1;
                        done <= 1;
                        state <= IDLE;
                    end else begin
                        window <= {window[MAX_WINDOW_CELLS-2:0], sampled_power};
                        active_training_cells_left <= training_cells_left;
                        active_training_cells_right <= training_cells_right;
                        active_guard_cells_left <= guard_cells_left;
                        active_guard_cells_right <= guard_cells_right;
                        active_training_cell_count <= training_cells_left + training_cells_right;
                        active_alpha <= alpha;
                        active_cut <= cut;
                        done <= 0;
                        state <= SUM_START;
                    end
                end

                SUM_START: begin
                    done <= 0;
                    state <= SUM_WAIT;
                end

                SUM_WAIT: begin
                    done <= 0;
                    if (training_sum_valid_out) begin
                        if (active_training_cell_count == 0) begin
                            training_average <= 0;
                        end else begin
                            training_average <= training_sum / active_training_cell_count;
                        end
                        state <= DETECTION;
                    end
                end

                DETECTION: begin
                    if (THRESHOLD_WIDTH'(window[active_cut]) > threshold) begin
                        detection_map <= 1; // Detected
                    end else begin
                        detection_map <= 0; // Not detected
                    end
                    done <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
