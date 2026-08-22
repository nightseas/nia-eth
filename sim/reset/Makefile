# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the transceiver reset request gate.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_reset_main
COCOTB_RESULTS_FILE ?= results_reset_main.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(HERE)/../../rtl

GATE_SRC ?= $(RTL_DIR)/gt_rst_req_gate.sv

VERILOG_SOURCES := \
  $(GATE_SRC) \
  $(RTL_DIR)/dcmac_sync2.sv

TOPLEVEL := gt_rst_req_gate
MODULE   := test_gt_rst_req_gate

export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

PULSE_CYC    ?= 16
SETTLE_CYC   ?= 20
DONE_TMO_CYC ?= 200
EN_GATE      ?= 1

export GATE_PULSE_CYC    := $(PULSE_CYC)
export GATE_SETTLE_CYC   := $(SETTLE_CYC)
export GATE_DONE_TMO_CYC := $(DONE_TMO_CYC)
export GATE_EN_GATE      := $(EN_GATE)

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE \
                  -Wno-DECLFILENAME
    COMPILE_ARGS += -GPULSE_CYC=$(PULSE_CYC) -GSETTLE_CYC=$(SETTLE_CYC) \
                    -GDONE_TMO_CYC=$(DONE_TMO_CYC) -GEN_GATE=$(EN_GATE)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: lint
lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME \
	  --top-module gt_rst_req_gate $(RTL_DIR)/gt_rst_req_gate.sv \
	  $(RTL_DIR)/dcmac_sync2.sv
	@echo "NIA_DPRST_LINT_OK (WIDTH warnings were ENABLED)"
