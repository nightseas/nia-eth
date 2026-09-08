# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for one adapter against the control plane, over
#               tb_dcmac_adapter_link.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_seam_main
COCOTB_RESULTS_FILE ?= results_seam_main.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

MODEL_DIR := $(shell pwd)/../model
TB_DIR := $(shell pwd)/../tb
RTL_DIR := $(shell pwd)/../../rtl
export PYTHONPATH := $(shell pwd):$(shell pwd)/..:$(PYTHONPATH)

VERILOG_SOURCES := \
  $(RTL_DIR)/dcmac_seg_axis_rx.sv \
                   $(RTL_DIR)/dcmac_seg_axis_adapter.sv \
  $(RTL_DIR)/eth_axis_dwidth.sv \
  $(MODEL_DIR)/eth_axis_async_fifo.sv \
  $(RTL_DIR)/dcmac_axis_frame_fifo.sv \
  $(MODEL_DIR)/tx_frame_fifo.sv \
  $(RTL_DIR)/ctl/dcmac_mac_ctl_fsm.sv \
  $(RTL_DIR)/dcmac_axis_rx_stream.sv \
  $(RTL_DIR)/dcmac_axis_adapter.sv \
  $(TB_DIR)/tb_dcmac_adapter_link.sv

TOPLEVEL := tb_dcmac_adapter_link
MODULE   := test_dcmac_axis_adapter

export N_SEG     ?= 2
export SEG_W     ?= 128
export DATA_W    ?= $(shell expr 2 \* $(N_SEG) \* $(SEG_W))
export TX_MHZ    ?= 250
export RX_MHZ    ?= 250
export NPORTS    ?= 1
export ANCHOR    ?= 0
export PTP_TS_EN ?= 0
export PTP_TS_W  ?= 80
export TX_TAG_W  ?= 0

export SEG_CYC_PER_MS ?= 20
export T_RXDP_MS      ?= 3
export T_SERDES_MS    ?= 2

SEED ?=
ifneq ($(SEED),)

    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE
    COMPILE_ARGS += -GNPORTS=$(NPORTS) -GANCHOR=$(ANCHOR)
    COMPILE_ARGS += -GN_SEG=$(N_SEG) -GSEG_W=$(SEG_W) -GDATA_W=$(DATA_W)
    COMPILE_ARGS += -GPTP_TS_EN=$(PTP_TS_EN) -GPTP_TS_W=$(PTP_TS_W) -GTX_TAG_W=$(TX_TAG_W)
    COMPILE_ARGS += -GSEG_CYC_PER_MS=$(SEG_CYC_PER_MS) -GT_RXDP_MS=$(T_RXDP_MS) \
                    -GT_SERDES_MS=$(T_SERDES_MS)

    ifeq ($(FF_BRAM),1)
        COMPILE_ARGS += +define+DCMAC_FRAME_FIFO_BRAM
    endif
    ifeq ($(TX_FF_BRAM),1)
        COMPILE_ARGS += +define+DCMAC_TX_FRAME_FIFO_BRAM
    endif
endif

export FF_BRAM    ?= 0
export TX_FF_BRAM ?= 0

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
