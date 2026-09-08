# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the transmit segment packer at the 200G geometry, over
#               tb_dcmac_seg_pack. The 100G and 400G geometries are the .g100 and .g400
#               variants, which include this file.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_seg_pack
COCOTB_RESULTS_FILE ?= results_seg_pack.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(HERE)/../../rtl
TB_DIR  := $(HERE)/../tb

VERILOG_SOURCES := $(RTL_DIR)/dcmac_seg_axis_rx.sv \
                   $(RTL_DIR)/dcmac_axis_frame_fifo.sv \
                   $(RTL_DIR)/dcmac_seg_axis_adapter.sv \
                   $(TB_DIR)/tb_dcmac_seg_pack.sv

TOPLEVEL := tb_dcmac_seg_pack
MODULE   := test_dcmac_seg_pack

export PYTHONPATH := $(HERE):$(HERE)/..:$(PYTHONPATH)

# The three geometries this repository builds. N_SEG and DATA_W come from
# example/TU03/fpga/rtl/fpga_axispg_dual_top.sv lines 72 to 74 and the DATA_W the flow sets
# per rate: 100G is 2x128 segments against a 512 bit stream, 200G is 4x128 against 1024, and
# 400G is 8x128 against 1024.
N_SEG   ?= 4
SEG_W   ?= 128
DATA_W  ?= 1024
MAX_LEN ?= 9018
FIFO_AW ?= 10
export N_SEG SEG_W DATA_W MAX_LEN

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE
    COMPILE_ARGS += -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) -GDATA_W=$(DATA_W) \
                    -GMAX_LEN=$(MAX_LEN) -GFIFO_AW=$(FIFO_AW)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
