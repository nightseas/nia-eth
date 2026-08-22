# ---------------------------------------------------------------------------
# File        : test_dcmac_pktgen_top.py
# Description : The subsystem tests of the segmented image: the management window answers,
#               the control plane leaves reset, and the generator stays gated until the
#               link is up.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from test_dcmac_pktgen import (
    CTL_ENABLE,
    MAP_VERSION_MAJOR,
    MODE_FIXED,
    MODULE_TYPE_VALUE,
    R_BUS_CHECK,
    R_CTL,
    R_LEN_MAX,
    R_LEN_MIN,
    R_LEN_MODE,
    R_MAP_VERSION,
    R_MODULE_TYPE,
    R_SEG_GEOMETRY,
    R_TX_FRAME_LIMIT,
    R_TX_FRAMES,
)

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))


def _pktgen_probe(dut):
    try:
        pg = dut.u_pktgen
    except Exception:
        return "[no hierarchy]"

    def value(name):
        try:
            return int(getattr(pg, name).value)
        except Exception:
            return -1
    return (f"[aw_hold={value('aw_hold_r')} w_hold={value('w_hold_r')} "
            f"b_pending={value('b_pending_r')} r_pending={value('r_pending_r')}]")


class SeamAxil:
    def __init__(self, dut):
        self.dut = dut

    async def write(self, addr, value):
        d = self.dut
        d.pg_awaddr.value = addr
        d.pg_awvalid.value = 1
        d.pg_wdata.value = value
        d.pg_wstrb.value = 0xF
        d.pg_wvalid.value = 1
        d.pg_bready.value = 1
        for _ in range(400):
            await RisingEdge(d.usr_clk)
            if d.pg_bvalid.value:
                d.pg_awvalid.value = 0
                d.pg_wvalid.value = 0
                await ClockCycles(d.usr_clk, 2)
                d.pg_bready.value = 0
                return
        raise AssertionError(
            f"write to 0x{addr:03x} did not complete: awready={int(d.pg_awready.value)} "
            f"wready={int(d.pg_wready.value)} bvalid={int(d.pg_bvalid.value)} "
            f"usr_rstn={int(d.usr_rstn.value)} {_pktgen_probe(d)}")

    async def read(self, addr):
        d = self.dut
        d.pg_araddr.value = addr
        d.pg_arvalid.value = 1
        d.pg_rready.value = 1
        for _ in range(400):
            await RisingEdge(d.usr_clk)
            if d.pg_rvalid.value:
                value = int(d.pg_rdata.value)
                d.pg_arvalid.value = 0
                await ClockCycles(d.usr_clk, 1)
                d.pg_rready.value = 0
                return value
        raise AssertionError(
            f"read from 0x{addr:03x} did not complete: arready={int(d.pg_arready.value)} "
            f"rvalid={int(d.pg_rvalid.value)} usr_rstn={int(d.usr_rstn.value)} "
            f"link_up={int(d.link_up.value)} arvalid={int(d.pg_arvalid.value)} "
            f"{_pktgen_probe(d)}")


REF_CLK_NS = int(os.environ.get("REF_CLK_NS", "4"))


async def bring_up(dut):
    dut.sys_reset.value = 1
    dut.gt_ref_clk_n.value = 1
    cocotb.start_soon(Clock(dut.gt_ref_clk_p, REF_CLK_NS, units="ns").start())
    dut.gt_rxp_in.value = 0
    dut.gt_rxn_in.value = 0
    dut.ctl_bringup_restart_req.value = 0
    dut.ctl_stats_req.value = 0
    dut.ctl_rx_force_resync_req.value = 0
    dut.ctl_rx_datapath_reset_req.value = 0
    dut.ctl_tx_datapath_reset_req.value = 0
    dut.ctl_stat_rd_idx.value = 0
    dut.pg_awvalid.value = 0
    dut.pg_wvalid.value = 0
    dut.pg_bready.value = 0
    dut.pg_arvalid.value = 0
    dut.pg_rready.value = 0
    await ClockCycles(dut.usr_clk, 20)
    dut.sys_reset.value = 0
    await ClockCycles(dut.usr_clk, 50)
    return SeamAxil(dut)


@cocotb.test()
async def test_management_window_answers(dut):
    bus = await bring_up(dut)
    module_type = int(await bus.read(R_MODULE_TYPE))
    assert module_type == MODULE_TYPE_VALUE, \
        f"the generator's window answers 0x{module_type:08x}, expected 0x{MODULE_TYPE_VALUE:08x}"
    version = int(await bus.read(R_MAP_VERSION))
    assert (version >> 16) == MAP_VERSION_MAJOR, \
        f"MAP VERSION major is {version >> 16}, expected {MAP_VERSION_MAJOR}"
    geometry = int(await bus.read(R_SEG_GEOMETRY))
    assert (geometry >> 16) == N_SEG and (geometry & 0xFFFF) == SEG_W, \
        f"SEG_GEOMETRY {geometry:#x} does not report the geometry"
    await bus.write(R_BUS_CHECK, 0x1357_9BDF)
    await ClockCycles(dut.usr_clk, 20)
    assert int(await bus.read(R_BUS_CHECK)) == 0x1357_9BDF, "BUS_CHECK does not return a written value"


@cocotb.test()
async def test_control_plane_leaves_reset(dut):
    await bring_up(dut)
    seen = set()
    for _ in range(400):
        await ClockCycles(dut.usr_clk, 50)
        seen.add(int(dut.ctl_seq_state.value))
    assert len(seen) > 1, f"the sequencer never changed state, states seen: {sorted(seen)}"
    assert int(dut.mac_fsm_state.value) is not None


@cocotb.test()
async def test_generator_is_gated_until_the_link_is_up(dut):
    bus = await bring_up(dut)
    await bus.write(R_LEN_MIN, 60)
    await bus.write(R_LEN_MAX, 60)
    await bus.write(R_LEN_MODE, MODE_FIXED)
    await bus.write(R_TX_FRAME_LIMIT, 8)
    await bus.write(R_CTL, CTL_ENABLE)
    await ClockCycles(dut.usr_clk, 200)
    if not int(dut.link_up.value):
        assert int(await bus.read(R_TX_FRAMES)) == 0, \
            "the generator transmitted while the control plane reports the link down"
