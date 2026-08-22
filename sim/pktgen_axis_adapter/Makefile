# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the AXI-Stream instrument through the adapter, over
#               tb_dcmac_axis_pktgen_adapter.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_pktgen_axis_adapter
COCOTB_RESULTS_FILE ?= results_pktgen_axis_adapter.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(HERE)/../../rtl
TB_DIR  := $(HERE)/../tb

VERILOG_SOURCES := $(RTL_DIR)/dcmac_sync2.sv \
                   $(RTL_DIR)/dcmac_csr_snap.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_frame_src.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_frame_chk.sv \
                   $(RTL_DIR)/pktgen_axis/dcmac_axis_pktgen.sv \
                   $(RTL_DIR)/eth_axis_dwidth.sv \
                   $(RTL_DIR)/dcmac_seg_axis_adapter.sv \
                   $(HERE)/../model/seg_pack_loop.sv \
                   $(HERE)/../model/eth_axis_async_fifo.sv \
                   $(RTL_DIR)/dcmac_axis_frame_fifo.sv \
                   $(HERE)/../model/tx_frame_fifo.sv \
                   $(RTL_DIR)/dcmac_axis_adapter.sv \
                   $(TB_DIR)/tb_dcmac_axis_pktgen_adapter.sv

TOPLEVEL := tb_dcmac_axis_pktgen_adapter
MODULE   := test_dcmac_axis_pktgen_adapter

export PYTHONPATH := $(HERE):$(HERE)/..:$(HERE)/../pktgen_axis:$(HERE)/../pktgen_axis_seam:$(PYTHONPATH)

DATA_W ?= 512
N_SEG  ?= 2
SEG_W  ?= 128
PACK_LOOP ?= 0
export DATA_W N_SEG SEG_W PACK_LOOP

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE
    COMPILE_ARGS += -GDATA_W=$(DATA_W) -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) -GPACK_LOOP=$(PACK_LOOP)
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
