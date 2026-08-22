# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the transceiver reconfiguration bridge.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_drp_main
COCOTB_RESULTS_FILE ?= results_drp_main.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TB_DIR := $(HERE)/../tb
RTL_DIR := $(HERE)/../../rtl

BRG_SRC ?= $(RTL_DIR)/dcmac_drp_bridge.sv

VERILOG_SOURCES := \
  $(BRG_SRC) \
  $(RTL_DIR)/ctl/dcmac_link_csr.sv \
  $(RTL_DIR)/dcmac_csr_snap.sv \
  $(TB_DIR)/tb_dcmac_drp_bridge.sv

N_WORD ?= 16
TOPLEVEL := tb_dcmac_drp_bridge
MODULE   := test_dcmac_drp_bridge

export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

TIMEOUT_CYC ?= 64
export DRP_TIMEOUT_CYC := $(TIMEOUT_CYC)

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE \
                  -Wno-DECLFILENAME
    COMPILE_ARGS += -GTIMEOUT_CYC=$(TIMEOUT_CYC)

    COMPILE_ARGS += -GN_WORD=$(N_WORD)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: lint
lint:
	verilator --lint-only -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME \
	  --top-module dcmac_drp_bridge $(RTL_DIR)/dcmac_drp_bridge.sv
	@echo "NIA_DRP_LINT_OK (WIDTH warnings were ENABLED)"
