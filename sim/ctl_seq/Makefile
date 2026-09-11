# ---------------------------------------------------------------------------
# File        : Makefile
# Description : The cocotb set for the bring-up sequencer, which is the reference
#               acceptance of the control plane.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Makefile
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

SIM_BUILD ?= sim_build_ctl_seq_main
COCOTB_RESULTS_FILE ?= results_ctl_seq_main.xml

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

HERE    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(HERE)/../../rtl/ctl

COYOTE_CTL_SIM ?= $(HERE)

VERILOG_SOURCES := \
  $(RTL_DIR)/dcmac_ctl_pkg.sv \
  $(RTL_DIR)/dcmac_ctl_seq.sv

TOPLEVEL := dcmac_ctl_seq
MODULE   := test_dcmac_ctl_seq

export PYTHONPATH := $(HERE):$(HERE)/..:$(COYOTE_CTL_SIM):$(PYTHONPATH)

export NPORTS      ?= 1
export ANCHOR      ?= 0
export CYC_PER_MS  ?= 20
export POLL_TRIES  ?= 3
export RATE_CODE   ?= 0
export RATE_FIELD  ?= 4
export DONE_MASK   ?= 3
GAP_MS      ?= 50
RX_CYCLES_G ?=

SEED ?=
ifneq ($(SEED),)
    export RANDOM_SEED        := $(SEED)
    export COCOTB_RANDOM_SEED := $(SEED)
endif

ifeq ($(SIM),verilator)
    EXTRA_ARGS += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
                  -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SELRANGE
    COMPILE_ARGS += -GNPORTS=$(NPORTS) -GANCHOR=$(ANCHOR) \
                    -GCYC_PER_MS=$(CYC_PER_MS) -GPOLL_TRIES=$(POLL_TRIES) \
                    -GRATE_CODE=$(RATE_CODE) -GRATE_FIELD=$(RATE_FIELD) \
                    -GDONE_MASK=$(DONE_MASK) -GT_PORT_CHAN_GAP_MS=$(GAP_MS)
    ifneq ($(RX_CYCLES_G),)
        COMPILE_ARGS += -GRX_CYCLES=$(RX_CYCLES_G)
    endif
endif

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

include $(shell cocotb-config --makefiles)/Makefile.sim
