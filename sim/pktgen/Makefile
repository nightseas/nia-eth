# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the segmented instrument in loopback, over
#               tb_dcmac_pktgen_loop.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_pktgen_main
COCOTB_RESULTS_FILE ?= results_pktgen_main.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(shell pwd)
RTL_DIR := $(HERE)/../../rtl
TB_DIR  := $(HERE)/../tb
export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

VERILOG_SOURCES := \
  $(RTL_DIR)/dcmac_sync2.sv \
  $(RTL_DIR)/dcmac_csr_snap.sv \
  $(RTL_DIR)/dcmac_seg_fifo.sv \
  $(RTL_DIR)/pktgen_seg/dcmac_seg_ctx.sv \
  $(RTL_DIR)/pktgen_seg/dcmac_seg_pktgen_chain.sv \
  $(RTL_DIR)/pktgen_seg/dcmac_seg_pktmon_chain.sv \
  $(RTL_DIR)/dcmac_seg_pktgen.sv \
  $(TB_DIR)/tb_dcmac_pktgen_loop.sv

TOPLEVEL := tb_dcmac_pktgen_loop
MODULE   := test_dcmac_pktgen

export N_SEG     ?= 2
export SEG_W     ?= 128
export STALL_CYC ?= 16
export SEG_MHZ   ?= 390
export AXIL_MHZ  ?= 250

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST \
                  -Wno-SELRANGE -Wno-DECLFILENAME
    COMPILE_ARGS += -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) -GSTALL_CYC=$(STALL_CYC)
endif

PLUSARGS += +nia_mon_no_stop

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: elab-check
elab-check:
	verilator --lint-only -sv -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	  --top-module $(TOPLEVEL) $(VERILOG_SOURCES)
