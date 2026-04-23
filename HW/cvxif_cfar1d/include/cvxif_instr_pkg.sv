// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
//
// Original Author: Guillaume Chauvon (guillaume.chauvon@thalesgroup.com)

package cvxif_instr_pkg;

  typedef enum logic [2:0] {
    ILLEGAL           = 3'b000,
    CFAR_RESET_WINDOW = 3'b001,
    CFAR_SET_ALPHA    = 3'b010,
    CFAR_SET_TRAINING = 3'b011,
    CFAR_SET_GUARD    = 3'b100,
    CFAR_RUN          = 3'b101
  } opcode_t;

  typedef struct packed {
    logic accept;
    logic writeback;           // TODO depends on dualwrite
    logic [2:0] register_read; // TODO Nr read ports
  } issue_resp_t;

  typedef struct packed {
    logic        accept;
    logic [31:0] instr;
  } compressed_resp_t;

  typedef struct packed {
    logic [31:0] instr;
    logic [31:0] mask;
    issue_resp_t resp;
    opcode_t     opcode;
  } copro_issue_resp_t;

  typedef struct packed {
    logic [15:0]      instr;
    logic [15:0]      mask;
    compressed_resp_t resp;
  } copro_compressed_resp_t;

  parameter int unsigned NbInstr = 5;
  parameter copro_issue_resp_t CoproInstr[NbInstr] = '{
      '{
          // Custom CFAR reset window state
          instr:
          32'b00000_00_00000_00000_0_00_00000_1111011,  // custom3 opcode
          mask: 32'b11111_11_00000_00000_1_11_00000_1111111,
          resp : '{accept : 1'b1, writeback : 1'b0, register_read : {1'b0, 1'b0, 1'b0}},
          opcode : CFAR_RESET_WINDOW
      },
      '{
          // Custom CFAR set alpha from rs1[31:0]
          instr:
          32'b00001_00_00000_00000_0_00_00000_1111011,  // custom3 opcode
          mask: 32'b11111_11_00000_00000_1_11_00000_1111111,
          resp : '{accept : 1'b1, writeback : 1'b0, register_read : {1'b0, 1'b0, 1'b1}},
          opcode : CFAR_SET_ALPHA
      },
      '{
          // Custom CFAR set training cells: rs1->left, rs2->right
          instr:
          32'b00010_00_00000_00000_0_00_00000_1111011,  // custom3 opcode
          mask: 32'b11111_11_00000_00000_1_11_00000_1111111,
          resp : '{accept : 1'b1, writeback : 1'b0, register_read : {1'b0, 1'b1, 1'b1}},
          opcode : CFAR_SET_TRAINING
      },
      '{
          // Custom CFAR set guard cells: rs1->left, rs2->right
          instr:
          32'b00011_00_00000_00000_0_00_00000_1111011,  // custom3 opcode
          mask: 32'b11111_11_00000_00000_1_11_00000_1111111,
          resp : '{accept : 1'b1, writeback : 1'b0, register_read : {1'b0, 1'b1, 1'b1}},
          opcode : CFAR_SET_GUARD
      },
      '{
          // Custom CFAR run one input sample: rs1=data_in, rd<=detection_map[7:0]
          instr:
          32'b00100_00_00000_00000_0_01_00000_1111011,  // custom3 opcode
          mask: 32'b11111_11_00000_00000_1_11_00000_1111111,
          resp : '{accept : 1'b1, writeback : 1'b1, register_read : {1'b0, 1'b0, 1'b1}},
          opcode : CFAR_RUN
      }
  };

  parameter int unsigned NbCompInstr = 1;
  parameter copro_compressed_resp_t CoproCompInstr[NbCompInstr] = '{
      '{
          instr : 16'b0000000000000000,
          mask : 16'b1111111111111111,
          resp : '{accept : 1'b0, instr : 32'b0}
      }
  };

endpackage
