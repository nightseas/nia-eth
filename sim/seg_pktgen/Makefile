# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the segmented instrument: dcmac_seg_pktgen driven at
#               its register block and its client interface.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_seg_pktgen
COCOTB_RESULTS_FILE ?= results_seg_pktgen.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
THIS_MK := $(lastword $(MAKEFILE_LIST))
RTL_DIR := $(HERE)/../../rtl

VERILOG_SOURCES := $(RTL_DIR)/dcmac_sync2.sv \
                   $(RTL_DIR)/dcmac_csr_snap.sv \
                   $(RTL_DIR)/dcmac_seg_fifo.sv \
                   $(RTL_DIR)/pktgen_seg/dcmac_seg_ctx.sv \
                   $(RTL_DIR)/pktgen_seg/dcmac_seg_pktgen_chain.sv \
                   $(RTL_DIR)/pktgen_seg/dcmac_seg_pktmon_chain.sv \
                   $(RTL_DIR)/dcmac_seg_pktgen.sv

TOPLEVEL := dcmac_seg_pktgen
MODULE   := test_dcmac_seg_pktgen

export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

N_SEG ?= 2
SEG_W ?= 128
LEN_MIN_HW ?= 60
LEN_MAX_HW ?= 1518
export N_SEG
export SEG_W
export LEN_MIN_HW
export LEN_MAX_HW

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE -Wno-LATCH \
                  -Wno-DECLFILENAME
    COMPILE_ARGS += -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) \
                    -GLEN_MIN_HW=$(LEN_MIN_HW) -GLEN_MAX_HW=$(LEN_MAX_HW)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: quad lint
quad:
	$(MAKE) -f $(THIS_MK) N_SEG=4

lint:
	verilator --lint-only -sv --timing -Wall -Wno-DECLFILENAME -Wno-VARHIDDEN \
	  -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET -Wno-UNUSEDPARAM \
	  -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) --top-module dcmac_seg_pktgen $(VERILOG_SOURCES)
