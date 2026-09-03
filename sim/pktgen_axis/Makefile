# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the AXI-Stream instrument in loopback, over
#               tb_dcmac_axis_pktgen_loop.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_pktgen_axis
COCOTB_RESULTS_FILE ?= results_pktgen_axis.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
THIS_MK := $(lastword $(MAKEFILE_LIST))
RTL_DIR := $(HERE)/../../rtl
TB_DIR  := $(HERE)/../tb

VERILOG_SOURCES := $(RTL_DIR)/dcmac_sync2.sv \
                   $(RTL_DIR)/dcmac_csr_snap.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_frame_src.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_frame_chk.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_pktgen.sv \
                   $(TB_DIR)/tb_dcmac_axis_pktgen_loop.sv

TOPLEVEL := tb_dcmac_axis_pktgen_loop
MODULE   := test_dcmac_axis_pktgen

export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

DATA_W ?= 512
LEN_MIN_HW ?= 64
LEN_MAX_HW ?= 9018
export DATA_W
export LEN_MIN_HW
export LEN_MAX_HW

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE
    COMPILE_ARGS += -GDATA_W=$(DATA_W) \
                    -GLEN_MIN_HW=$(LEN_MIN_HW) -GLEN_MAX_HW=$(LEN_MAX_HW)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: legacy
legacy:
	$(MAKE) -f $(THIS_MK) LEN_MAX_HW=1518
