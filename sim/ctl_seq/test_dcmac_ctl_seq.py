# ---------------------------------------------------------------------------
# File        : test_dcmac_ctl_seq.py
# Description : The sequencer tests: unattended bring-up, the golden configuration trace,
#               a closed register set, no frame check sequence register written, and the
#               gap the hard block requires between a port and a channel.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

from axil_slave_bfm import AxiLiteSlaveBFM
import golden as G

NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
POLL_TRIES = int(os.environ.get("POLL_TRIES", "3"))
RATE_CODE = int(os.environ.get("RATE_CODE", "0"))
RATE_FIELD = int(os.environ.get("RATE_FIELD", "4"))
LANE_RATE_HI = int(os.environ.get("LANE_RATE_HI", "1")) != 0
DONE_MASK = int(os.environ.get("DONE_MASK", "3"))
RX_CYCLES = 6 if NPORTS > 1 else 3
CLK_NS = 4

MS_BUDGET = 400 + RX_CYCLES * (2 * 200 + 200 + POLL_TRIES * 200 + 200)
CYC_BUDGET = MS_BUDGET * CYC_PER_MS + 40000

def _rnd(dut):
    return random.Random(random.getrandbits(32))

async def _start(dut, rd_cb, max_delay=3):
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
    bfm = AxiLiteSlaveBFM(dut, dut.aclk, rnd=_rnd(dut), rd_cb=rd_cb,
                          max_delay=max_delay)
    await bfm.start()
    await ClockCycles(dut.aclk, 8)
    dut.aresetn.value = 1
    dut.gt_tx_reset_done.value = DONE_MASK
    dut.gt_rx_reset_done.value = DONE_MASK
    await ClockCycles(dut.aclk, 2)
    return bfm

def _status_cb(align_after_cycle=None, values=None, bfm_holder=None):
    addr_status = G.pp(ANCHOR, G.O_RX_PHY_STATUS)
    state = {"n": 0}

    def cb(addr, n):
        if addr == addr_status:
            state["n"] += 1
            if values is not None:
                i = min(state["n"] - 1, len(values) - 1)
                return values[i]
            if align_after_cycle is None:
                return 0x0
            return 0x5 if state["n"] > align_after_cycle else 0x0
        return (addr ^ 0xA5A5) & 0xFFFFFFFF

    return cb

async def _wait_settle(dut, limit=None):
    limit = limit or CYC_BUDGET
    for _ in range(limit):
        await RisingEdge(dut.aclk)
        if int(dut.bringup_done.value) or int(dut.link_fault.value):
            return True
    dut._log.error(
        "settle timeout after %d cycles: seq_state=%d seq_pc=%d seq_busy=%d "
        "bringup_done=%d access_fault=%d link_up=%d link_live=%d rx_phy_status=0x%08X",
        limit, int(dut.seq_state.value), int(dut.seq_pc.value), int(dut.seq_busy.value),
        int(dut.bringup_done.value), int(dut.access_fault.value), int(dut.link_up.value),
        int(dut.link_live.value), int(dut.rx_phy_status.value))
    return False

def _cfg_golden():
    return G.config_phase(nports=NPORTS, anchor=ANCHOR, rate=RATE_CODE,
                          field=RATE_FIELD, lane_hi=LANE_RATE_HI)

def _first_index(tuples, needle):
    for i, t in enumerate(tuples):
        if t == needle:
            return i
    return -1

@cocotb.test()
async def test_c13_unattended_bringup(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0))
    ok = await _wait_settle(dut)
    assert ok, "sequencer never halted"
    assert int(dut.bringup_done.value) == 1, "the sequencer did not finish unattended"
    assert int(dut.link_fault.value) == 0
    assert int(dut.retry_cnt.value) == 0, "the happy path used the retry ladder"
    assert len(bfm.writes()) > 60, f"only {len(bfm.writes())} writes issued"
    assert len(bfm.reads()) > 0
    assert int(dut.tx_datapath_reset.value) == 0

@cocotb.test()
async def test_c6_golden_trace_config_phase(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=1)
    assert await _wait_settle(dut)
    got = [x.as_tuple() for x in bfm.writes()]
    exp = _cfg_golden()

    d = os.environ.get("TRACE_DIR", ".")
    fmt = lambda t: "\n".join(
        f"{i:4d} {k} 0x{a:05x} 0x{v:08x}" for i, (k, a, v) in enumerate(t))
    with open(os.path.join(d, f"trace_observed_np{NPORTS}.txt"), "w") as fh:
        fh.write(fmt(got[:len(exp)]) + "\n")
    with open(os.path.join(d, f"trace_golden_np{NPORTS}.txt"), "w") as fh:
        fh.write(fmt(exp) + "\n")
    with open(os.path.join(d, f"trace_full_np{NPORTS}.txt"), "w") as fh:
        fh.write("\n".join(f"{i:4d} {x.kind} 0x{x.addr:05x} 0x{x.data:08x} @{x.cycle}"
                           for i, x in enumerate(bfm.trace)) + "\n")

    assert len(got) >= len(exp), f"only {len(got)} writes, expected >= {len(exp)}"
    head = got[:len(exp)]
    if head != exp:
        for i, (g, e) in enumerate(zip(head, exp)):
            if g != e:
                raise AssertionError(
                    f"GOLDEN TRACE MISMATCH at write {i}: "
                    f"got ({g[0]} 0x{g[1]:05x} 0x{g[2]:08x}) "
                    f"expected ({e[0]} 0x{e[1]:05x} 0x{e[2]:08x})")
        raise AssertionError("golden trace length mismatch")
    tick = G.pmtick(nports=NPORTS, anchor=ANCHOR)
    assert got[len(exp):len(exp) + len(tick)] == tick, \
        f"the writes after the configuration phase are {got[len(exp):len(exp) + len(tick)]}, " \
        f"expected the pmtick block {tick}"
    cocotb.log.info("C6: %d config writes and %d pmtick writes matched the document exactly",
                    len(exp), len(tick))

@cocotb.test()
async def test_c7_closed_register_set(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=1))
    assert await _wait_settle(dut)
    allowed = G.closed_address_set()
    bad = sorted({x.addr for x in bfm.trace if x.addr not in allowed})
    assert not bad, "addresses outside the closed  set: " + \
                    ", ".join(f"0x{a:05x}" for a in bad)

@cocotb.test()
async def test_c21_no_fcs_register_written(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0))
    assert await _wait_settle(dut)
    allowed = G.closed_address_set()
    for x in bfm.writes():
        assert x.addr in allowed, f"wrote unvendored register 0x{x.addr:05x}"
    for x in bfm.trace:
        assert x.addr < 0x100000, f"address 0x{x.addr:x} outside the s_axi window"

@cocotb.test()
async def test_c8_port_channel_gap(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=0)
    assert await _wait_settle(dut)
    group = list(range(ANCHOR, ANCHOR + NPORTS))
    pctl = {G.pp(p, G.O_PCTL_RX) for p in range(G.PORT_MAX)} | \
           {G.pp(p, G.O_PCTL_TX) for p in range(G.PORT_MAX)} | \
           {G.O_PCTL_RX, G.O_PCTL_TX}
    chctl = {G.pp(p, G.O_CHCTL_RX) for p in group} | \
            {G.pp(p, G.O_CHCTL_TX) for p in group}
    ws = bfm.writes()
    ch_rel = next(x for x in ws if x.addr in chctl and x.data == 0)
    port_rel = [x for x in ws if x.addr in pctl and x.data == 0 and
                x.cycle < ch_rel.cycle]
    assert port_rel, "no PORT_CONTROL release seen before the channel release"
    gap = ch_rel.cycle - port_rel[-1].cycle
    want = 50 * CYC_PER_MS
    assert gap >= want, \
        f"B10 gap only {gap} cycles, need >= {want} (50 ms x CYC_PER_MS={CYC_PER_MS})"
    cocotb.log.info("C8: B10 gap = %d cycles (>= %d)", gap, want)

@cocotb.test()
async def test_c9_bad_magic_is_an_access_fault(dut):
    await _start(dut, _status_cb(values=[G.AXI_BAD]))
    assert await _wait_settle(dut), "the sequencer neither finished nor faulted"
    assert int(dut.access_fault.value) == 1, \
        "0x0BAD0BAD did not raise the access fault status"
    assert int(dut.link_fault.value) == 0, \
        "0x0BAD0BAD was reported as a link fault instead of an access fault"

@cocotb.test()
async def test_b16_tx_datapath_reset_never_asserted(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=None), max_delay=0)
    for _ in range(CYC_BUDGET):
        await RisingEdge(dut.aclk)
        assert int(dut.tx_datapath_reset.value) == 0, \
            f"B16 VIOLATED: tx_datapath_reset asserted at pc={int(dut.seq_pc.value)}"
        if int(dut.bringup_done.value):
            break
    assert int(dut.bringup_done.value) == 1

@cocotb.test()
async def test_c14_one_configuration_pass_only(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=None), max_delay=0)
    assert await _wait_settle(dut)
    assert int(dut.bringup_done.value) == 1, "the sequencer did not finish"
    n = len([x for x in bfm.writes() if x.addr == G.O_GLOBAL_MODE])
    assert n == 1, f"GLOBAL_MODE written {n} times - a second configuration pass ran"

@cocotb.test()
async def test_c15_reentrancy_identical_trace(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=0)
    assert await _wait_settle(dut)
    first = [x.as_tuple() for x in bfm.trace]
    assert int(dut.bringup_done.value) == 1
    bfm.clear()
    dut.bringup_restart_req.value = 1
    await ClockCycles(dut.aclk, 2)
    dut.bringup_restart_req.value = 0
    await ClockCycles(dut.aclk, 20)
    assert int(dut.bringup_done.value) == 0, "bringup_done not cleared on restart"
    assert await _wait_settle(dut)
    second = [x.as_tuple() for x in bfm.trace]
    assert int(dut.bringup_done.value) == 1
    assert first == second, (
        f"re-entrant trace differs: {len(first)} vs {len(second)} transactions; "
        f"first divergence at "
        f"{next((i for i, (a, b) in enumerate(zip(first, second)) if a != b), 'len')}")


@cocotb.test()
async def test_c16_status_and_stats_readback(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=0)
    assert await _wait_settle(dut)
    assert int(dut.bringup_done.value) == 1
    exp = G.stats_reads(nports=NPORTS, anchor=ANCHOR)
    assert len(bfm.reads()) >= len(exp), \
        f"only {len(bfm.reads())} reads, expected at least {len(exp)}"
    stat_rd = bfm.reads()
    for i in range(min(len(exp), 22 * NPORTS)):
        dut.stat_rd_idx.value = i
        await ClockCycles(dut.aclk, 2)
        got = int(dut.stat_rd_data.value)
        assert got == stat_rd[i].data, \
            f"stat_q[{i}] = 0x{got:08x}, expected 0x{stat_rd[i].data:08x}"

@cocotb.test()
async def test_c17_host_overrides(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=0)
    assert await _wait_settle(dut)
    assert int(dut.bringup_done.value) == 1
    assert int(dut.rx_force_resync.value) == 0
    dut.rx_force_resync_req.value = 1
    await ClockCycles(dut.aclk, 2)
    assert int(dut.rx_force_resync.value) == 1
    dut.rx_force_resync_req.value = 0
    await ClockCycles(dut.aclk, 2)
    assert int(dut.rx_force_resync.value) == 0, "rx_force_resync did not self-clear"
    assert int(dut.rx_datapath_reset.value) == 0
    dut.rx_datapath_reset_req.value = 1
    await ClockCycles(dut.aclk, 2)
    assert int(dut.rx_datapath_reset.value) == 1
    mask = int(dut.rx_datapath_reset_ports.value)
    want = sum(1 << p for p in range(ANCHOR, ANCHOR + NPORTS))
    assert mask == want, f"group mask 0x{mask:x}, expected 0x{want:x}"
    dut.rx_datapath_reset_req.value = 0
    await ClockCycles(dut.aclk, 2)
    assert int(dut.rx_datapath_reset.value) == 0
    dut.tx_datapath_reset_req.value = 1
    await ClockCycles(dut.aclk, 2)
    assert int(dut.tx_datapath_reset.value) == 1
    dut.tx_datapath_reset_req.value = 0
    await ClockCycles(dut.aclk, 2)
    assert int(dut.tx_datapath_reset.value) == 0

@cocotb.test()
async def test_c18_pmtick_before_counter_reads(dut):
    bfm = await _start(dut, _status_cb(align_after_cycle=0), max_delay=0)
    assert await _wait_settle(dut)
    ticks = {G.pp(p, o) for p in range(ANCHOR, ANCHOR + NPORTS)
             for o in (G.O_TICK_RX, G.O_TICK_TX)}
    status = G.pp(ANCHOR, G.O_RX_PHY_STATUS)
    counter_reads = [x for x in bfm.reads() if x.addr != status]
    assert counter_reads, "no counter reads at all - C18 would be vacuous"
    last_tick = max((x.cycle for x in bfm.writes() if x.addr in ticks
                     and x.cycle < counter_reads[0].cycle), default=None)
    assert last_tick is not None, "a counter burst ran with no preceding pmtick"
    between = [x for x in bfm.writes()
               if last_tick < x.cycle < counter_reads[0].cycle]
    assert not between, f"{len(between)} non-tick write(s) between pmtick and the read"
    n0 = len(bfm.reads())
    dut.stats_req.value = 1
    await ClockCycles(dut.aclk, 2)
    dut.stats_req.value = 0
    for _ in range(CYC_BUDGET):
        await RisingEdge(dut.aclk)
        if len(bfm.reads()) > n0 + 4:
            break
    burst2 = bfm.reads()[n0:]
    assert burst2, "stats_req produced no second burst"
    t2 = [x for x in bfm.writes() if x.addr in ticks and x.cycle < burst2[0].cycle]
    assert len(t2) >= 2 * 2 * NPORTS, \
        "the repeat burst was not preceded by its own pmtick"

@cocotb.test()
async def test_c1_c2_c3_build_time_constants(dut):
    src = open(os.path.join(os.path.dirname(__file__), "..", "..",
                            "rtl", "ctl", "dcmac_ctl_pkg.sv")).read()
    for want in ("TX_MAIN_DEFAULT = 87", "TX_PRE_DEFAULT  = 17",
                 "TX_POST_DEFAULT = 5", "LOOPBACK_EXTERNAL = 3'b000",
                 "QSFP0_TXPOLARITY", "QSFP0_RXPOLARITY"):
        assert want in src, f"dcmac_ctl_pkg.sv is missing `{want}` (C1/C2/C3)"

    def legal(m, p, q):
        return 42 <= m <= 87 and 0 <= p <= 24 and 0 <= q <= 24 and (p + q) < m
    assert legal(87, 17, 5), "the measured-best cursor set must be legal"
    assert legal(75, 3, 9), "the vendor A/B cursor set must be legal"
    assert not legal(0, 0, 0), "C2: a zero cursor set must be REJECTED"
    await Timer(1, units="ns")
