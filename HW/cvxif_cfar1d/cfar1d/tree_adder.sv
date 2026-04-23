module tree_adder #(
    parameter int N = 8,
    parameter int DATA_WIDTH = 32,
    parameter int SUM_WIDTH = DATA_WIDTH + ((N <= 1) ? 0 : $clog2(N))
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  valid_in,
    input  var logic [DATA_WIDTH-1:0] a [N-1:0],
    output logic [SUM_WIDTH-1:0]  sum,
    output logic                  valid_out
);

    generate
        if (N == 1) begin : gen_single_input
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sum <= '0;
                    valid_out <= 1'b0;
                end else begin
                    sum <= SUM_WIDTH'(a[0]);
                    valid_out <= valid_in;
                end
            end
        end else begin : gen_tree
            localparam int STAGES = $clog2(N);

            logic [SUM_WIDTH-1:0] stage [0:STAGES][0:N-1];
            logic [STAGES-1:0] valid_pipe;

            genvar input_i;
            for (input_i = 0; input_i < N; input_i++) begin : gen_input_extend
                assign stage[0][input_i] = SUM_WIDTH'(a[input_i]);
            end

            genvar level_i;
            genvar node_i;
            for (level_i = 0; level_i < STAGES; level_i++) begin : gen_level
                localparam int INPUTS = (N + (1 << level_i) - 1) >> level_i;
                localparam int OUTPUTS = (INPUTS + 1) / 2;

                for (node_i = 0; node_i < OUTPUTS; node_i++) begin : gen_node
                    if ((2 * node_i + 1) < INPUTS) begin : gen_add
                        logic [SUM_WIDTH-1:0] add_sum;

                        adder #(
                            .WIDTH(SUM_WIDTH)
                        ) u_adder (
                            .a(stage[level_i][2 * node_i]),
                            .b(stage[level_i][2 * node_i + 1]),
                            .sum(add_sum)
                        );

                        always_ff @(posedge clk or negedge rst_n) begin
                            if (!rst_n) begin
                                stage[level_i + 1][node_i] <= '0;
                            end else begin
                                stage[level_i + 1][node_i] <= add_sum;
                            end
                        end
                    end else begin : gen_pass
                        always_ff @(posedge clk or negedge rst_n) begin
                            if (!rst_n) begin
                                stage[level_i + 1][node_i] <= '0;
                            end else begin
                                stage[level_i + 1][node_i] <= stage[level_i][2 * node_i];
                            end
                        end
                    end
                end

                for (node_i = OUTPUTS; node_i < N; node_i++) begin : gen_unused
                    always_ff @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            stage[level_i + 1][node_i] <= '0;
                        end else begin
                            stage[level_i + 1][node_i] <= '0;
                        end
                    end
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_pipe <= '0;
                end else begin
                    valid_pipe[0] <= valid_in;
                    for (int i = 1; i < STAGES; i++) begin
                        valid_pipe[i] <= valid_pipe[i - 1];
                    end
                end
            end

            assign sum = stage[STAGES][0];
            assign valid_out = valid_pipe[STAGES - 1];
        end
    endgenerate

endmodule
