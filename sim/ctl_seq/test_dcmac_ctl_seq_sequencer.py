# ---------------------------------------------------------------------------
# File        : test_dcmac_ctl_seq_sequencer.py
# Description : The tests of the sequencer in isolation: it halts unattended, its golden
#               write trace is unchanged, it publishes no link state, it issues no poll
#               write, and its halt is restartable.
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
from cocotb.triggers import RisingEdge, ClockCycles

from axil_slave_bfm import AxiLiteSlaveBFM
import golden as G

NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
RATE_CODE = int(os.environ.get("RATE_CODE", "0"))
RATE_FIELD = int(os.environ.get("RATE_FIELD", "4"))
LANE_RATE_HI = int(os.environ.get("LANE_RATE_HI", "1")) != 0
DONE_MASK = int(os.environ.get("DONE_MASK", "3"))

CLK_NS = 4

MS_BUDGET = 400 + 6 * (2 * 200 + 200 + 200)
CYC_BUDGET = MS_BUDGET * CYC_PER_MS + 40000

print(f"NIA t2 seq: NPORTS={NPORTS} ANCHOR={ANCHOR} CYC_PER_MS={CYC_PER_MS} "
      f"CYC_BUDGET={CYC_BUDGET}", flush=True)

def _rnd(dut):
    import random
    return random.Random(int(os.environ.get("RANDOM_SEED", "1")))

def _status_cb(aligned=True):
    addr_status = G.pp(ANCHOR, G.O_RX_PHY_STATUS)
    state = {"n": 0}

    def cb(addr, n):
        if addr == addr_status:
            state["n"] += 1
            return 0x5 if aligned else 0x0
        return (addr ^ 0xA5A5) & 0xFFFFFFFF

    return cb

async def _start(dut, rd_cb=None, max_delay=3):
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
    bfm = AxiLiteSlaveBFM(dut, dut.aclk, rnd=_rnd(dut),
                          rd_cb=rd_cb or _status_cb(), max_delay=max_delay)
    await bfm.start()
    await ClockCycles(dut.aclk, 8)
    dut.aresetn.value = 1
    dut.gt_tx_reset_done.value = DONE_MASK
    dut.gt_rx_reset_done.value = DONE_MASK
    await ClockCycles(dut.aclk, 2)
    return bfm

async def _wait_halt(dut, limit=None):
    limit = limit or CYC_BUDGET
    for _ in range(limit):
        await RisingEdge(dut.aclk)
        if int(dut.bringup_done.value):
            return True
    return False

@cocotb.test()
async def test_tc_the_sequencer_halts_unattended(dut):
    await _start(dut)
    ok = await _wait_halt(dut)
    assert ok, (
        f"the sequencer did not halt within {CYC_BUDGET} cycles.  truncated the ROM; if this fails, "
        f"the truncation left a record that cannot complete, and the reference suite's failures are a "
        f"real defect and not the removal documented in "
    )
    assert int(dut.link_fault.value) == 0, (
        "`link_fault` rose.  deleted `OP_FAULT` - there must be no state from which recovery is "
        "impossible, so nothing may drive this"
    )

@cocotb.test()
async def test_tc_golden_write_trace_unchanged(dut):
    bfm = await _start(dut)
    await _wait_halt(dut)
    got = [x.as_tuple() for x in bfm.writes()]
    want = G.config_phase(nports=NPORTS, anchor=ANCHOR, rate=RATE_CODE, field=RATE_FIELD,
                          lane_hi=LANE_RATE_HI)
    n = len(want)
    assert len(got) >= n, (
        f"the sequencer issued {len(got)} writes, fewer than the golden config phase's {n}.  "
        f"requires the configuration writes to be unchanged by this work"
    )
    for i, (exp, act) in enumerate(zip(want, got[:n])):
        assert tuple(exp) == tuple(act), (
            f" VIOLATED at write {i}: golden {exp} != actual {act}. The bring-up write sequence is "
            f"the control for every change in this area and it must stay byte-identical"
        )
    print(f"NIA_TRACE_OK golden={n} writes matched byte-for-byte", flush=True)

@cocotb.test()
async def test_tc_no_link_state_is_published(dut):
    await _start(dut)
    worst = 0
    for _ in range(CYC_BUDGET // 4):
        await RisingEdge(dut.aclk)
        worst |= int(dut.link_up.value) | int(dut.link_live.value)
        if worst:
            break
    assert worst == 0, (
        "the sequencer published a link state.  removed `OP_UP` so `link_up_r` can only be cleared; "
        "if this fails, a latched publication has been restored and defect  is reachable again"
    )

@cocotb.test()
async def test_tc_no_poll_write_is_ever_issued(dut):
    bfm = await _start(dut)
    await _wait_halt(dut)
    got = [x.as_tuple() for x in bfm.writes()]
    offenders = [t for t in got if (t[1] & 0xFFF) == 0xC00]
    assert not offenders, (
        f"the sequencer wrote the poll-variant register: {offenders[:4]}. That write IS defect  - it "
        f"manufactures a latched bit which then cannot change until it is re-issued"
    )

@cocotb.test()
async def test_tc_halt_is_restartable(dut):
    await _start(dut)
    assert await _wait_halt(dut), "the sequencer did not halt the first time"
    dut.bringup_restart_req.value = 1
    await ClockCycles(dut.aclk, 4)
    dut.bringup_restart_req.value = 0
    ran_again = False
    for _ in range(CYC_BUDGET):
        await RisingEdge(dut.aclk)
        if not int(dut.bringup_done.value):
            ran_again = True
            break
    assert ran_again, (
        "`CTL[0]` did not restart the program. C15 requires a restart to clear all sequencer state, and "
        "this is the only host path to reconfiguration left"
    )
    assert await _wait_halt(dut), "the restarted program did not halt"
