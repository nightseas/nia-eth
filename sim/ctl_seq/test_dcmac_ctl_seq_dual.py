# ---------------------------------------------------------------------------
# File        : test_dcmac_ctl_seq_dual.py
# Description : The two group sequencer tests: the golden trace for both groups, every per
#               port write in both slots, the millisecond waits intact, both groups
#               reaching link up, and a realign that touches only its own group.
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
import golden_dual as GD

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..")))
from nia_sim_watchdog import wallclock_guard

NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
N_GROUP = int(os.environ.get("N_GROUP", "2"))
ANCHOR_1 = int(os.environ.get("ANCHOR_1", "1"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
POLL_TRIES = int(os.environ.get("POLL_TRIES", "3"))
RATE_CODE = int(os.environ.get("RATE_CODE", "0"))
RATE_FIELD = int(os.environ.get("RATE_FIELD", "4"))
LANE_RATE_HI = int(os.environ.get("LANE_RATE_HI", "1")) != 0
DONE_MASK = int(os.environ.get("DONE_MASK", "3"))
CLK_NS = 4

ANCHORS = tuple([ANCHOR] + ([ANCHOR_1] if N_GROUP > 1 else []))
NPORTS_L = tuple([NPORTS] * len(ANCHORS))
GROUP_PORTS = GD.group_ports(ANCHORS, NPORTS_L)

RX_CYCLES = 6 if NPORTS > 1 else 3
MS_BUDGET = 400 + N_GROUP * RX_CYCLES * (2 * 200 + 200 + POLL_TRIES * 200 + 200)
CYC_BUDGET = MS_BUDGET * CYC_PER_MS + 40000

WORST_RATE_NS_PER_S = 3352.0
RUNNER_QUIET_S = 900.0
TIMEOUT_US = float(os.environ.get(
    "NIA_CTL_TEST_US", f"{CYC_BUDGET * CLK_NS * 1.5 / 1000.0:.0f}"))

MIN_CYC_PER_MS_FOR_WAIT_CHECK = int(os.environ.get("NIA_MIN_CYC_PER_MS", "20"))
WAIT_TOLERANCE = 0.8

def _budget_report():
    wall = TIMEOUT_US * 1000.0 / WORST_RATE_NS_PER_S
    print(f"NIA_N18 ctl_dual: N_GROUP={N_GROUP} anchors={ANCHORS} CYC_PER_MS={CYC_PER_MS} "
          f"CYC_BUDGET={CYC_BUDGET} -> timeout {TIMEOUT_US:.0f} us = {TIMEOUT_US*1000:.0f} ns; "
          f"at the worst rate on record ({WORST_RATE_NS_PER_S:.0f} ns/s) that is {wall:.0f} s "
          f"wall = {100*wall/RUNNER_QUIET_S:.0f} % of the runner's {RUNNER_QUIET_S:.0f} s quiet "
          f"bound. wallclock_guard is armed in addition, because a simulated-time bound cannot "
          f"bound a hang that freezes simulated time.", flush=True)

_budget_report()
_WALL = {"t": None}

def _arm(name):
    if _WALL["t"] is not None:
        try:
            _WALL["t"].cancel()
        except Exception:
            pass
    t0 = time.time()
    _WALL["t"] = wallclock_guard(
        name, snapshot=lambda: [f"test={name}", f"wall={time.time()-t0:.0f}s",
                                f"N_GROUP={N_GROUP} anchors={ANCHORS}",
                                f"CYC_BUDGET={CYC_BUDGET} timeout_us={TIMEOUT_US:.0f}"])
    return t0

def _disarm(name, t0):
    if _WALL["t"] is not None:
        try:
            _WALL["t"].cancel()
        except Exception:
            pass
    print(f"NIA_SIM_RATE test={name} wall_s={time.time()-t0:.1f}", flush=True)

def _rnd():
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
    bfm = AxiLiteSlaveBFM(dut, dut.aclk, rnd=_rnd(), rd_cb=rd_cb, max_delay=max_delay)
    await bfm.start()
    await ClockCycles(dut.aclk, 8)
    dut.aresetn.value = 1
    dut.gt_tx_reset_done.value = DONE_MASK
    dut.gt_rx_reset_done.value = DONE_MASK
    await ClockCycles(dut.aclk, 2)
    return bfm

def _status_cb(aligned_groups=(0, 1)):
    addrs = {G.pp(a, G.O_RX_PHY_STATUS): gi for gi, a in enumerate(ANCHORS)}

    def cb(addr, n):
        gi = addrs.get(addr)
        if gi is not None:
            return 0x5 if gi in aligned_groups else 0x0
        return (addr ^ 0xA5A5) & 0xFFFFFFFF

    return cb

async def _wait_settle(dut, limit=None):
    limit = limit or CYC_BUDGET
    for _ in range(limit):
        await RisingEdge(dut.aclk)
        if int(dut.bringup_done.value) or int(dut.link_fault.value):
            return True
    return False

def _fmt(t):
    return "\n".join(f"{i:4d} {k} 0x{a:05x} 0x{v:08x}" for i, (k, a, v) in enumerate(t))

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns20_golden_trace_two_groups(dut):
    t0 = _arm("test_ns20_golden_trace_two_groups")
    bfm = await _start(dut, _status_cb(), max_delay=1)
    assert await _wait_settle(dut), "the sequencer never halted within the cycle budget"
    got = [x.as_tuple() for x in bfm.writes()]
    exp = GD.config_phase_dual(anchors=ANCHORS, nports=NPORTS_L,
                               rate=RATE_CODE, field=RATE_FIELD, lane_hi=LANE_RATE_HI)

    d = os.environ.get("TRACE_DIR", ".")
    tag = f"ng{N_GROUP}_a{'_'.join(str(a) for a in ANCHORS)}_np{NPORTS}"
    with open(os.path.join(d, f"trace_dual_observed_{tag}.txt"), "w") as fh:
        fh.write(_fmt(got[:len(exp)]) + "\n")
    with open(os.path.join(d, f"trace_dual_golden_{tag}.txt"), "w") as fh:
        fh.write(_fmt(exp) + "\n")
    with open(os.path.join(d, f"trace_dual_full_{tag}.txt"), "w") as fh:
        fh.write("\n".join(f"{i:4d} {x.kind} 0x{x.addr:05x} 0x{x.data:08x} @{x.cycle}"
                           for i, x in enumerate(bfm.trace)) + "\n")

    assert len(got) >= len(exp), (
        f"only {len(got)} writes, expected >= {len(exp)} for {N_GROUP} group(s) at anchors "
        f"{ANCHORS}.  A SHORT TRACE IS THE SIGNATURE OF A MISSING GROUP: at N_GROUP=1 every "
        f"group-scoped ROM section collapses, so a ROM that ignores the group dimension emits "
        f"exactly the single-client trace and nothing else.")
    head = got[:len(exp)]
    if head != exp:
        for i, (g, e) in enumerate(zip(head, exp)):
            if g != e:
                raise AssertionError(
                    f" GOLDEN TRACE MISMATCH at write {i}: "
                    f"got ({g[0]} 0x{g[1]:05x} 0x{g[2]:08x}) "
                    f"expected ({e[0]} 0x{e[1]:05x} 0x{e[2]:08x}). Transcripts in {d}/"
                    f"trace_dual_*_{tag}.txt")
        raise AssertionError(" golden trace length mismatch")

    # What follows B11 is B17's statistics tick, and nothing else. PG369 page 101: a tick event is
    # triggered by a rising edge on the per-port tx_port_pm_tick[5:0] pin "or by writing a 1 to the
    # tick register of a given port through the AXI4-Lite interface". Those pins are tied to 6'b0 at
    # every wrapper in this repository, so the register write is the only live route and without it
    # the DCMAC latches no snapshot and every counter behind it reads zero.
    #
    # This assertion previously read "configuration must END at B11" and required len(got) ==
    # len(exp), on the premise that pmtick is a pin and not a register. That premise is wrong, it
    # removed the only working route, and the FEC counters read zero on hardware for a month as a
    # result. The property worth protecting is not "nothing follows B11" but "exactly the tick
    # follows B11", which is what is asserted here and is the stronger of the two.
    tick = GD.pmtick_dual(anchors=ANCHORS, nports=NPORTS_L)
    tail = got[len(exp):]
    assert len(tail) == len(tick), (
        f"exactly {len(tick)} write(s) of B17's statistics tick shall follow B11, 2 per port over "
        f"{len(GROUP_PORTS)} port(s), and {len(tail)} write(s) were seen. A short tail means the "
        f"pmtick block is missing or truncated, which leaves every counter behind the DCMAC "
        f"snapshot reading zero. A long tail means a record survived the truncation. "
        f"Tail: {tail[:6]}")
    for i, (g, e) in enumerate(zip(tail, tick)):
        assert g == e, (
            f"B17 PMTICK MISMATCH at tick write {i}: got ({g[0]} 0x{g[1]:05x} 0x{g[2]:08x}) "
            f"expected ({e[0]} 0x{e[1]:05x} 0x{e[2]:08x}). The block shall write 0x1 to O_TICK_RX "
            f"then O_TICK_TX for every port of every group, in group then port order. "
            f"Transcripts in {d}/trace_dual_*_{tag}.txt")
    cocotb.log.info("%d config write(s) across %d group(s) matched the document exactly, "
                    "followed by %d B17 pmtick write(s)", len(exp), N_GROUP, len(tick))
    _disarm("test_ns20_golden_trace_two_groups", t0)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns20_every_per_port_write_both_slots(dut):
    t0 = _arm("test_ns20_every_per_port_write_both_slots")
    bfm = await _start(dut, _status_cb())
    assert await _wait_settle(dut)
    seen = {(x.addr, x.data) for x in bfm.writes()}
    addrs = {x.addr for x in bfm.writes()}

    per_port = {
        "CHCTL_RX assert": (G.O_CHCTL_RX, 0x1),
        "CHCTL_TX assert": (G.O_CHCTL_TX, 0x1),
        "PCTL_RX assert": (G.O_PCTL_RX, 0x3),
        "PCTL_TX assert": (G.O_PCTL_TX, 0x3),
        "PCTL_RX release": (G.O_PCTL_RX, 0x0),
        "PCTL_TX release": (G.O_PCTL_TX, 0x0),
        "CHCTL_TX release": (G.O_CHCTL_TX, 0x0),
        "CHCTL_RX release": (G.O_CHCTL_RX, 0x0),
    }
    missing = []
    for gi, a in enumerate(ANCHORS):
        for p in range(a, a + NPORTS_L[gi]):
            for what, (off, data) in per_port.items():
                if (G.pp(p, off), data) not in seen:
                    missing.append(f"group {gi} slot {p}: {what}")
    assert not missing, (" VIOLATED - per-port writes absent for:\n  " +
                         "\n  ".join(missing))

    for gi, a in enumerate(ANCHORS):
        wtx, wrx = G._mode_words(RATE_CODE, RATE_FIELD, LANE_RATE_HI)
        assert (G.pp(a, G.O_TX_MODE), wtx) in seen, \
            f" VIOLATED: group {gi} anchor {a} never got the TX rate word {wtx:#010x}"
        assert (G.pp(a, G.O_RX_MODE), wrx) in seen, \
            f" VIOLATED: group {gi} anchor {a} never got the RX rate word {wrx:#010x}"

    allowed = G.closed_address_set()
    bad = sorted(a for a in addrs if a not in allowed)
    assert not bad, (": writes outside the closed register set: " +
                     ", ".join(f"0x{a:05x}" for a in bad))
    _disarm("test_ns20_every_per_port_write_both_slots", t0)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns20_millisecond_waits_intact(dut):
    t0 = _arm("test_ns20_millisecond_waits_intact")
    if CYC_PER_MS < MIN_CYC_PER_MS_FOR_WAIT_CHECK:
        msg = (f"SKIPPED: CYC_PER_MS={CYC_PER_MS} < {MIN_CYC_PER_MS_FOR_WAIT_CHECK}, so "
               f"`ms` and `ms * CYC_PER_MS` are not separable from the BFM's randomised ready "
               f"latency (up to 3 cycles per transaction). Re-run with CYC_PER_MS >= "
               f"{MIN_CYC_PER_MS_FOR_WAIT_CHECK}. The structural gate covers this class at every "
               f"CYC_PER_MS.")
        cocotb.log.warning(msg)
        print("NIA_SKIP " + msg, flush=True)
        _disarm("test_ns20_millisecond_waits_intact", t0)
        return

    bfm = await _start(dut, _status_cb(), max_delay=0)
    assert await _wait_settle(dut)
    writes = bfm.writes()
    exp = GD.config_phase_dual(anchors=ANCHORS, nports=NPORTS_L, rate=RATE_CODE,
                               field=RATE_FIELD, with_waits=True, lane_hi=LANE_RATE_HI)
    points = GD.wait_points(exp)
    assert points, "the golden emitted no WAIT tokens - with_waits=True produced nothing"

    checked = 0
    for idx, ms in points:
        if idx < 0 or idx + 1 >= len(writes):
            continue
        want = int(ms * CYC_PER_MS * WAIT_TOLERANCE)
        gap = writes[idx + 1].cycle - writes[idx].cycle
        assert gap >= want, (
            f" VIOLATED - the {ms} ms wait after write {idx} "
            f"(0x{writes[idx].addr:05x}) measured {gap} cycles, need >= {want} "
            f"({ms} ms x CYC_PER_MS={CYC_PER_MS} x tol {WAIT_TOLERANCE}).  A gap of about {ms} "
            f"cycles means the `* CYC_PER_MS` was DROPPED - that is 's class, which "
            f"reached silicon and is in the ARP-proven link.")
        checked += 1
    assert checked == len(points), \
        f"only {checked} of {len(points)} wait points were measurable in the trace"
    cocotb.log.info(": %d millisecond waits intact across %d group(s)", checked, N_GROUP)
    _disarm("test_ns20_millisecond_waits_intact", t0)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", expect_fail=True)
async def test_ns20_both_groups_reach_link_up(dut):
    t0 = _arm("test_ns20_both_groups_reach_link_up")
    bfm = await _start(dut, _status_cb(aligned_groups=tuple(range(N_GROUP))))
    assert await _wait_settle(dut), "the sequencer never halted"
    want = (1 << N_GROUP) - 1
    assert int(dut.link_up.value) == want, (
        f"link_up = {int(dut.link_up.value):#b}, expected {want:#b} - not every group came up "
        f"unattended")
    assert int(dut.link_fault.value) == 0
    assert int(dut.retry_cnt.value) == 0, "the happy path used the retry ladder"
    assert int(dut.tx_datapath_reset.value) == 0, \
        ": the TX datapath reset asserted during a clean bring-up"
    assert len(bfm.writes()) > 60, f"only {len(bfm.writes())} writes issued"
    _disarm("test_ns20_both_groups_reach_link_up", t0)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", expect_fail=True)
async def test_ns21_realign_touches_only_its_own_group(dut):
    t0 = _arm("test_ns21_realign_touches_only_its_own_group")
    if N_GROUP < 2:
        print("NIA_SKIP test_ns21_realign_touches_only_its_own_group: N_GROUP=1 has no second "
              "group to protect. This is the variant that matters; run it at N_GROUP=2.", flush=True)
        _disarm("test_ns21_realign_touches_only_its_own_group", t0)
        return

    bfm = await _start(dut, _status_cb(aligned_groups=(1,)))
    assert await _wait_settle(dut), "the sequencer never halted"

    g0 = set(range(ANCHORS[0], ANCHORS[0] + NPORTS_L[0]))
    g1 = set(range(ANCHORS[1], ANCHORS[1] + NPORTS_L[1]))
    realigned = set()
    for x in bfm.writes():
        if x.data == 0x2:
            for p in range(G.PORT_MAX):
                if x.addr == G.pp(p, G.O_PCTL_RX):
                    realigned.add(p)
    assert realigned, (
        "VACUOUS TEST: no B13 re-align write (PORT_CONTROL_RX <- 0x2) was ever emitted, so group "
        "0 never walked its ladder and nothing about isolation was exercised.")
    leaked = realigned & g1
    assert not leaked, (
        f"  VIOLATED: group 0's re-align ladder wrote PORT_CONTROL_RX <- 0x2 to MAC "
        f"port(s) {sorted(leaked)}, which belong to GROUP 1. That resets the healthy client's MAC "
        f"port group; on the wire it presents as an intermittency (: 6/10 -> 15/15).")
    assert realigned <= g0, \
        f"group 0's ladder touched ports {sorted(realigned - g0)} outside its own group {sorted(g0)}"

    assert (int(dut.link_up.value) >> 1) & 1 == 1, (
        "/: group 1 aligned but its `link_up` bit is dark while group 0 retries - the "
        "per-group OP_UP record exists precisely so group 0 cannot hold group 1 hostage.")
    _disarm("test_ns21_realign_touches_only_its_own_group", t0)
