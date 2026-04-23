// Copyright 2024 Thales DIS France SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Guillaume Chauvon

module copro_alu
  import cvxif_instr_pkg::*;
#(
    parameter int unsigned NrRgprPorts = 2,
    parameter int unsigned XLEN = 32,
    parameter int unsigned CFAR_MAX_WINDOW_CELLS = 64,
    parameter type hartid_t = logic,
    parameter type id_t = logic,
    parameter type registers_t = logic

) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  registers_t            registers_i,
    input  opcode_t               opcode_i,
    input  hartid_t               hartid_i,
    input  id_t                   id_i,
    input  logic       [     4:0] rd_i,
    input  logic                  issue_fire_i,
    output logic       [XLEN-1:0] result_o,
    output hartid_t               hartid_o,
    output id_t                   id_o,
    output logic       [     4:0] rd_o,
    output logic                  valid_o,
    output logic                  we_o,
    output logic                  busy_o
);

  localparam int unsigned kInputWidth = (XLEN < 32) ? XLEN : 32;

  logic [XLEN-1:0] result_n, result_q;
  hartid_t hartid_n, hartid_q;
  id_t id_n, id_q;
  logic valid_n, valid_q;
  logic [4:0] rd_n, rd_q;
  logic we_n, we_q;

  logic        cfar_reset_window;
  logic        cfar_start;
  logic [31:0] cfar_data_in;
  logic [7:0]  cfar_detection_map_w;
  logic        cfar_done_w;

  logic [31:0] alpha_q;
  logic [31:0] training_cells_left_q;
  logic [31:0] training_cells_right_q;
  logic [31:0] guard_cells_left_q;
  logic [31:0] guard_cells_right_q;

  logic cfar_busy_q;
  logic cfar_wb_pending_q;
  logic cfar_done_prev_q;
  logic cfar_done_pulse;

  logic [4:0] cfar_rd_q;
  hartid_t cfar_hartid_q;
  id_t cfar_id_q;

  logic        cfg_alpha_en;
  logic        cfg_training_en;
  logic        cfg_guard_en;
  logic [31:0] cfg_alpha_data;
  logic [31:0] cfg_training_left_data;
  logic [31:0] cfg_training_right_data;
  logic [31:0] cfg_guard_left_data;
  logic [31:0] cfg_guard_right_data;

  logic [31:0] rs1_word;
  logic [31:0] rs2_word;

  assign result_o = result_q;
  assign hartid_o = hartid_q;
  assign id_o     = id_q;
  assign valid_o  = valid_q;
  assign rd_o     = rd_q;
  assign we_o     = we_q;
  assign busy_o   = cfar_busy_q;

  assign cfar_done_pulse = cfar_done_w && ~cfar_done_prev_q;

  always_comb begin
    rs1_word = '0;
    rs2_word = '0;
    rs1_word[kInputWidth-1:0] = registers_i[0][kInputWidth-1:0];
    if (NrRgprPorts > 1) begin
      rs2_word[kInputWidth-1:0] = registers_i[1][kInputWidth-1:0];
    end
  end

  assign cfar_data_in = rs1_word;

  cfar_1d #(
      .MAX_WINDOW_CELLS(CFAR_MAX_WINDOW_CELLS)
  ) cfar_1d_i (
      .clk                (clk_i),
      .rst_n              (rst_ni),
      .reset_window       (cfar_reset_window),
      .alpha              (alpha_q),
      .training_cells_left(training_cells_left_q),
      .training_cells_right(training_cells_right_q),
      .guard_cells_left   (guard_cells_left_q),
      .guard_cells_right  (guard_cells_right_q),
      .start              (cfar_start),
      .done               (cfar_done_w),
      .data_in            (cfar_data_in),
      .detection_map      (cfar_detection_map_w)
  );

  always_comb begin
    cfar_reset_window = 1'b0;
    cfar_start = 1'b0;
    cfg_alpha_en = 1'b0;
    cfg_training_en = 1'b0;
    cfg_guard_en = 1'b0;
    cfg_alpha_data = '0;
    cfg_training_left_data = '0;
    cfg_training_right_data = '0;
    cfg_guard_left_data = '0;
    cfg_guard_right_data = '0;

    result_n = '0;
    hartid_n = '0;
    id_n     = '0;
    valid_n  = 1'b0;
    rd_n     = '0;
    we_n     = 1'b0;

    if (cfar_done_pulse && cfar_wb_pending_q) begin
      result_n[7:0] = cfar_detection_map_w;
      hartid_n = cfar_hartid_q;
      id_n     = cfar_id_q;
      valid_n  = 1'b1;
      rd_n     = cfar_rd_q;
      we_n     = 1'b1;
    end else begin
      case (opcode_i)
        cvxif_instr_pkg::CFAR_RESET_WINDOW: begin
          if (issue_fire_i) begin
            cfar_reset_window = 1'b1;
            hartid_n          = hartid_i;
            id_n              = id_i;
            valid_n           = 1'b1;
            rd_n              = '0;
            we_n              = 1'b0;
          end
        end
        cvxif_instr_pkg::CFAR_SET_ALPHA: begin
          if (issue_fire_i) begin
            cfg_alpha_en   = 1'b1;
            cfg_alpha_data = rs1_word;
            hartid_n       = hartid_i;
            id_n           = id_i;
            valid_n        = 1'b1;
            rd_n           = '0;
            we_n           = 1'b0;
          end
        end
        cvxif_instr_pkg::CFAR_SET_TRAINING: begin
          if (issue_fire_i) begin
            cfg_training_en = 1'b1;
            cfg_training_left_data = rs1_word;
            cfg_training_right_data = rs2_word;
            hartid_n = hartid_i;
            id_n     = id_i;
            valid_n  = 1'b1;
            rd_n     = '0;
            we_n     = 1'b0;
          end
        end
        cvxif_instr_pkg::CFAR_SET_GUARD: begin
          if (issue_fire_i) begin
            cfg_guard_en = 1'b1;
            cfg_guard_left_data = rs1_word;
            cfg_guard_right_data = rs2_word;
            hartid_n = hartid_i;
            id_n     = id_i;
            valid_n  = 1'b1;
            rd_n     = '0;
            we_n     = 1'b0;
          end
        end
        cvxif_instr_pkg::CFAR_RUN: begin
          cfar_start = issue_fire_i && ~cfar_busy_q;
        end
        default: begin
          result_n = '0;
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      result_q <= '0;
      hartid_q <= '0;
      id_q     <= '0;
      valid_q  <= '0;
      rd_q     <= '0;
      we_q     <= '0;
    end else begin
      result_q <= result_n;
      hartid_q <= hartid_n;
      id_q     <= id_n;
      valid_q  <= valid_n;
      rd_q     <= rd_n;
      we_q     <= we_n;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      alpha_q <= 32'd1;
      training_cells_left_q <= '0;
      training_cells_right_q <= '0;
      guard_cells_left_q <= '0;
      guard_cells_right_q <= '0;
      cfar_busy_q <= 1'b0;
      cfar_wb_pending_q <= 1'b0;
      cfar_done_prev_q <= 1'b0;
      cfar_rd_q <= '0;
      cfar_hartid_q <= '0;
      cfar_id_q <= '0;
    end else begin
      cfar_done_prev_q <= cfar_done_w;

      if (cfg_alpha_en) begin
        alpha_q <= cfg_alpha_data;
      end
      if (cfg_training_en) begin
        training_cells_left_q <= cfg_training_left_data;
        training_cells_right_q <= cfg_training_right_data;
      end
      if (cfg_guard_en) begin
        guard_cells_left_q <= cfg_guard_left_data;
        guard_cells_right_q <= cfg_guard_right_data;
      end

      if (cfar_reset_window) begin
        cfar_busy_q <= 1'b0;
        cfar_wb_pending_q <= 1'b0;
      end

      if (cfar_start) begin
        cfar_busy_q <= 1'b1;
        cfar_wb_pending_q <= 1'b1;
        cfar_rd_q <= rd_i;
        cfar_hartid_q <= hartid_i;
        cfar_id_q <= id_i;
      end

      if (cfar_done_pulse) begin
        cfar_busy_q <= 1'b0;
        cfar_wb_pending_q <= 1'b0;
      end
    end
  end

endmodule
