# ---------------------------------------------------------------------------
# File        : test_dcmac_ctl_seq_link_latched.py
# Description : The declared negative control of the latched link view: it is expected to
#               fail, and what it fails on is the record of what the latched view does not
#               carry.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random
import sys
import time

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from axil_slave_bfm import AxiLiteSlaveBFM
import golden as G

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..")))
from nia_sim_watchdog import wallclock_guard

NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
N_GROUP = int(os.environ.get("N_GROUP", "2"))
ANCHOR_1 = int(os.environ.get("ANCHOR_1", "1"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
POLL_TRIES = int(os.environ.get("POLL_TRIES", "3"))
MON_POLL_TRIES = int(os.environ.get("MON_POLL_TRIES", "2"))
T_MON_MS = int(os.environ.get("T_MON_MS", "5"))
LINK_CONFIRM_N = int(os.environ.get("LINK_CONFIRM_N", "2"))
MON_MAX_REALIGN = int(os.environ.get("MON_MAX_REALIGN", "3"))
DONE_MASK = int(os.environ.get("DONE_MASK", "3"))

CLK_NS = 4
ANCHORS = tuple([ANCHOR] + ([ANCHOR_1] if N_GROUP > 1 else []))
RX_CYCLES = 6 if NPORTS > 1 else 3

MS_ROUND = N_GROUP * (T_MON_MS + MON_POLL_TRIES * 200) + 2 * 200 + 200
MS_BRINGUP = 400 + N_GROUP * RX_CYCLES * (2 * 200 + 200 + POLL_TRIES * 200 + 200)
MS_BUDGET = MS_BRINGUP + (MON_MAX_REALIGN + 10) * LINK_CONFIRM_N * MS_ROUND + 6 * MS_BRINGUP
CYC_BUDGET = MS_BUDGET * CYC_PER_MS + 60000
TIMEOUT_US = float(os.environ.get("NIA_NS56_TEST_US",
                                 f"{CYC_BUDGET * CLK_NS * 1.5 / 1000.0:.0f}"))
SETTLE_CYC = CYC_BUDGET // 2
ROUND_CYC = MS_ROUND * CYC_PER_MS + 4000

FALL_BOUND_CYC = 6 * (LINK_CONFIRM_N + 1) * ROUND_CYC

print(f"NIA_N18 ctl_ns56: N_GROUP={N_GROUP} anchors={ANCHORS} T_MON_MS={T_MON_MS} "
      f"LINK_CONFIRM_N={LINK_CONFIRM_N} CYC_BUDGET={CYC_BUDGET} ROUND_CYC={ROUND_CYC} "
      f"FALL_BOUND_CYC={FALL_BOUND_CYC} -> timeout {TIMEOUT_US:.0f} us", flush=True)

_WALL = {"t": None}

def _arm(name):
    t0 = time.time()
    _WALL["t"] = wallclock_guard(name, snapshot=lambda: [
        f"test={name}", f"wall={time.time()-t0:.0f}s", f"anchors={ANCHORS}",
        f"FALL_BOUND_CYC={FALL_BOUND_CYC}"])
    return t0

def _disarm(name, t0):
    if _WALL["t"] is not None:
        try:
            _WALL["t"].cancel()
        except Exception:
            pass
        _WALL["t"] = None
    print(f"NIA_SIM_RATE test={name} wall_s={time.time()-t0:.1f}", flush=True)

class PerGroupAlign:
    def __init__(self):
        self.aligned = {gi: True for gi in range(N_GROUP)}
        self.reads = {gi: 0 for gi in range(N_GROUP)}
        self._addr = {G.pp(a, G.O_RX_PHY_STATUS): gi for gi, a in enumerate(ANCHORS)}

    def cb(self, addr, n):
        gi = self._addr.get(addr)
        if gi is None:
            return (addr ^ 0xA5A5) & 0xFFFFFFFF
        self.reads[gi] += 1
        return 0x5 if self.aligned[gi] else 0x0

async def _start(dut, model):
    cocotb.start_soon(Clock(dut.aclk, CLK_NS, units="ns").start())
    dut.aresetn.value = 0
    dut.bringup_restart_req.value = 0
    dut.stats_req.value = 0
    dut.rx_force_resync_req.value = 0
    dut.rx_datapath_reset_req.value = 0
    dut.tx_datapath_reset_req.value = 0
    dut.stat_rd_idx.value = 0
    dut.gt_tx_reset_done.value = 0
    dut.gt_rx_reset_done.value = 0
    bfm = AxiLiteSlaveBFM(dut, dut.aclk, rnd=random.Random(0x56),
                          rd_cb=model.cb, max_delay=3)
    await bfm.start()
    await ClockCycles(dut.aclk, 8)
    dut.aresetn.value = 1
    dut.gt_tx_reset_done.value = DONE_MASK
    dut.gt_rx_reset_done.value = DONE_MASK
    await ClockCycles(dut.aclk, 2)
    return bfm

def _up(dut, gi):
    return (int(dut.link_up.value) >> gi) & 1

def _live(dut, gi):
    return (int(dut.link_live.value) >> gi) & 1

async def _await(dut, pred, limit):
    for _ in range(limit):
        await RisingEdge(dut.aclk)
        if pred():
            return True
    return False

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", skip=(N_GROUP < 2))
async def test_ns56_a_group_in_a_ladder_does_not_freeze_its_sibling(dut):
    t0 = _arm("ns56_sibling_not_frozen")
    try:
        m = PerGroupAlign()
        await _start(dut, m)

        assert await _await(dut, lambda: _up(dut, 0) == 1 and _up(dut, 1) == 1, SETTLE_CYC), (
            "neither group came up, so nothing below is a test of ")

        m.aligned[0] = False
        assert await _await(dut, lambda: _up(dut, 0) == 0, FALL_BOUND_CYC), (
            "group 0's own view never fell, so the stimulus never reached the sequencer")

        r1 = m.reads[1]
        m.aligned[1] = False

        fell_live = await _await(dut, lambda: _live(dut, 1) == 0, FALL_BOUND_CYC)
        polls_1 = m.reads[1] - r1
        assert fell_live, (
            f" VIOLATED: group 1's LIVE view never fell within {FALL_BOUND_CYC} cycles after "
            f"its own responder went unaligned, while group 0 was escalating. Group 1 was polled "
            f"{polls_1} time(s) in that window. This is the  silicon defect: a port "
            f"reporting `Link detected: yes` with the cable out and no eye on its receiver. "
            f"=> If this assertion fires on the pre- RTL, that is the EXPECTED result and the "
            f"evidence for the defect; do not weaken the test.")

        fell_up = await _await(dut, lambda: _up(dut, 1) == 0, FALL_BOUND_CYC)
        assert fell_up, (
            f" VIOLATED: group 1's LATCHED view never fell within {FALL_BOUND_CYC} cycles. "
            f"The latched view is what reaches netdev carrier at ALIGN_EXPORT_MODE = 0, which is the "
            f"configuration the defect was reproduced in.")
    finally:
        _disarm("ns56_sibling_not_frozen", t0)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", skip=(N_GROUP < 2))
async def test_ns56_the_sibling_is_still_polled_while_a_group_escalates(dut):
    t0 = _arm("ns56_sibling_still_polled")
    try:
        m = PerGroupAlign()
        await _start(dut, m)
        assert await _await(dut, lambda: _up(dut, 0) == 1 and _up(dut, 1) == 1, SETTLE_CYC), \
            "both groups must come up first"
        m.aligned[0] = False
        assert await _await(dut, lambda: _up(dut, 0) == 0, FALL_BOUND_CYC), \
            "group 0's view never fell"
        r1 = m.reads[1]
        await ClockCycles(dut.aclk, FALL_BOUND_CYC)
        polls = m.reads[1] - r1
        print(f"NIA_NS56 group1_polls_while_group0_escalates={polls} "
              f"window_cyc={FALL_BOUND_CYC}", flush=True)
        assert polls >= 2, (
            f"group 1 was polled only {polls} time(s) in {FALL_BOUND_CYC} cycles while group 0 "
            f"escalated. A group that is not polled cannot have a current view, whatever the clear "
            f"path does - this is the starvation half of.")
    finally:
        _disarm("ns56_sibling_still_polled", t0)
