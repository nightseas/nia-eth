# ---------------------------------------------------------------------------
# File        : test_dcmac_dual.py
# Description : The two client tests: the client buses are independent, both directions
#               are byte exact at once, an overflow or an abort on one client does not
#               disturb the other, and the group masks are disjoint and owned.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random
import logging
import sys
import time

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout
from cocotb.utils import get_sim_time

from cocotbext.axi import (AxiStreamBus, AxiStreamSource, AxiStreamMonitor,
                           AxiStreamFrame)

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..")))
from seg_bfm import SegmentedSource, SegmentedSink
from seg_bfm_multi import client_view, axis_prefix
from nia_sim_watchdog import wallclock_guard

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
PTP_TS_EN = int(os.environ.get("PTP_TS_EN", "0"))
PTP_TS_W = int(os.environ.get("PTP_TS_W", "80"))
TX_TAG_W = int(os.environ.get("TX_TAG_W", "0"))

NPORTS_C0 = int(os.environ.get("NPORTS_C0", "1"))
ANCHOR_C0 = int(os.environ.get("ANCHOR_C0", "0"))
NPORTS_C1 = int(os.environ.get("NPORTS_C1", "1"))
ANCHOR_C1 = int(os.environ.get("ANCHOR_C1", "1"))
PORT_MAX = int(os.environ.get("PORT_MAX", "6"))

RX_USER_W = (PTP_TS_W + 1) if PTP_TS_EN else 1
TX_USER_W = TX_TAG_W + 1

DATA_W = 512
BYTE_LANES = DATA_W // 8

TX_MHZ = float(os.environ.get("TX_MHZ", "250"))
RX_MHZ = float(os.environ.get("RX_MHZ", "250"))
SEG_PERIOD_NS = 2.56

AWAIT_US = float(os.environ.get("NIA_AWAIT_US", "300"))
TEST_US = float(os.environ.get("NIA_TEST_US", "1200"))
WORST_RATE_NS_PER_S = 3352.0
RUNNER_QUIET_S = 900.0

S_IDLE, S_GT_LOCKED, S_WAIT_ALIGN, S_XFER, S_RX_RESET = 0, 1, 2, 3, 4

SEG_CYC_PER_MS = int(os.environ.get("SEG_CYC_PER_MS", "20"))
T_RXDP_MS = int(os.environ.get("T_RXDP_MS", "3"))
T_SERDES_MS = int(os.environ.get("T_SERDES_MS", "2"))
RESET_CYC = (T_RXDP_MS + T_SERDES_MS) * SEG_CYC_PER_MS + 16

CLIENTS = (0, 1)
ANCHORS = {0: ANCHOR_C0, 1: ANCHOR_C1}
NPORTS = {0: NPORTS_C0, 1: NPORTS_C1}

def _group_mask(client):
    a, n = ANCHORS[client], NPORTS[client]
    return sum(1 << p for p in range(a, a + n))

def _period(mhz):
    return round(1000.0 / mhz * 500) / 500

TX_PERIOD_NS = _period(TX_MHZ)
RX_PERIOD_NS = _period(RX_MHZ)

def _rand_frame(n):
    return bytes(random.randint(0, 255) for _ in range(n))

_WALL = {"t": None}

def _arm_wall(name, dut):
    if _WALL["t"] is not None:
        try:
            _WALL["t"].cancel()
        except Exception:
            pass
    started = time.time()

    def snap():
        return [f"test={name}", f"wall_elapsed={time.time() - started:.0f}s",
                f"AWAIT_US={AWAIT_US} TEST_US={TEST_US}",
                f"variant: TX_MHZ={TX_MHZ} RX_MHZ={RX_MHZ} "
                f"ANCHOR_C0={ANCHOR_C0} ANCHOR_C1={ANCHOR_C1}"]

    _WALL["t"] = wallclock_guard(name, snapshot=snap)
    return started

def _report_rate(name, started):
    wall = max(time.time() - started, 1e-6)
    sim_ns = float(get_sim_time("ns"))
    rate = sim_ns / wall
    budget = rate * RUNNER_QUIET_S
    print(f"NIA_SIM_RATE test={name} sim_ns={sim_ns:.0f} wall_s={wall:.1f} "
          f"rate_ns_per_s={rate:.0f} reachable_sim_ns_in_{RUNNER_QUIET_S:.0f}s={budget:.0f} "
          f"(worst-on-record divisor used for the bounds = {WORST_RATE_NS_PER_S:.0f})", flush=True)
    if _WALL["t"] is not None:
        try:
            _WALL["t"].cancel()
        except Exception:
            pass

_CLKS = {}
_BG = []

def _bg(coro):
    t = cocotb.start_soon(coro)
    _BG.append(t)
    return t

def _start_clocks(dut, rx_mhz=None):
    for t in list(_CLKS.values()) + _BG:
        try:
            t.kill()
        except Exception:
            pass
    _CLKS.clear()
    del _BG[:]
    _CLKS["seg"] = cocotb.start_soon(Clock(dut.seg_clk, SEG_PERIOD_NS, units="ns").start())
    _CLKS["tx"] = cocotb.start_soon(Clock(dut.tx_clk, TX_PERIOD_NS, units="ns").start())
    _CLKS["rx"] = cocotb.start_soon(
        Clock(dut.rx_clk, RX_PERIOD_NS if rx_mhz is None else _period(rx_mhz), units="ns").start())

async def _reset(dut, aligned=0, configured=1):
    dut.seg_rstn.value = 0
    dut.tx_rstn.value = 0
    dut.rx_rstn.value = 0
    dut.seg_ptp_time.value = 0
    for k in CLIENTS:
        getattr(dut, f"stat_rx_aligned_c{k}").value = aligned
        getattr(dut, f"configured_c{k}").value = configured
        getattr(dut, f"stat_remote_fault_c{k}").value = 0
        getattr(dut, f"link_reset_req_c{k}").value = 0
        getattr(dut, f"host_tx_dp_req_c{k}").value = 0
        getattr(dut, f"rx_force_resync_req_c{k}").value = 0
        getattr(dut, f"gt_down_c{k}").value = 0
        getattr(dut, f"tx_seg_ready_c{k}").value = 1
        getattr(dut, f"m_axis_tx_cpl_c{k}_ready").value = 1
        getattr(dut, f"s_axis_tx_c{k}_tdata").value = 0
        getattr(dut, f"s_axis_tx_c{k}_tkeep").value = 0
        getattr(dut, f"s_axis_tx_c{k}_tvalid").value = 0
        getattr(dut, f"s_axis_tx_c{k}_tlast").value = 0
        getattr(dut, f"s_axis_tx_c{k}_tuser").value = 0
        getattr(dut, f"rx_seg_valid_c{k}").value = 0
        getattr(dut, f"rx_seg_dat_c{k}").value = 0
        getattr(dut, f"rx_seg_ena_c{k}").value = 0
        getattr(dut, f"rx_seg_sop_c{k}").value = 0
        getattr(dut, f"rx_seg_eop_c{k}").value = 0
        getattr(dut, f"rx_seg_err_c{k}").value = 0
        getattr(dut, f"rx_seg_mty_c{k}").value = 0
    await ClockCycles(dut.seg_clk, 8)
    await ClockCycles(dut.tx_clk, 8)
    await ClockCycles(dut.rx_clk, 8)
    dut.seg_rstn.value = 1
    dut.tx_rstn.value = 1
    dut.rx_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)

async def _bringup(dut, clients=CLIENTS):
    for k in clients:
        getattr(dut, f"stat_rx_aligned_c{k}").value = 1
    for _ in range(400):
        await RisingEdge(dut.seg_clk)
        if all(int(getattr(dut, f"ctl_tx_enable_c{k}").value) == 1 for k in clients):
            break
    for k in clients:
        assert int(getattr(dut, f"ctl_tx_enable_c{k}").value) == 1, \
            f"client {k} FSM never reached XFER: state={int(getattr(dut, f'fsm_state_c{k}').value)}"
    await ClockCycles(dut.tx_clk, 8)
    await ClockCycles(dut.rx_clk, 8)

def _views(dut):
    return {k: client_view(dut, k) for k in CLIENTS}

def _seg_sources(dut, views):
    return {k: SegmentedSource(views[k], dut.seg_clk, N_SEG, SEG_W) for k in CLIENTS}

def _seg_sinks(dut, views):
    return {k: SegmentedSink(views[k], dut.seg_clk, N_SEG, SEG_W,
                             ready_signal=f"tx_seg_ready_c{k}") for k in CLIENTS}

def _tx_sources(dut):
    out = {}
    for k in CLIENTS:
        s = AxiStreamSource(AxiStreamBus.from_prefix(dut, axis_prefix("s_axis_tx", k)),
                            dut.tx_clk, dut.tx_rstn, reset_active_level=False)
        s.log.setLevel(logging.WARNING)
        out[k] = s
    return out

def _rx_monitors(dut):
    out = {}
    for k in CLIENTS:
        m = AxiStreamMonitor(AxiStreamBus.from_prefix(dut, axis_prefix("m_axis_rx", k)),
                             dut.rx_clk, dut.rx_rstn, reset_active_level=False)
        m.log.setLevel(logging.WARNING)
        out[k] = m
    return out

def _rx_frame(fr):
    data = bytes(b for b, k in zip(fr.tdata, fr.tkeep) if k) if fr.tkeep is not None \
        else bytes(fr.tdata)
    tu = fr.tuser
    if tu is None:
        return data, 0
    if isinstance(tu, int):
        tu = [tu] * len(fr.tdata)
    return data, tu[-1] & 1

def _drain(mon):
    out = []
    while not mon.empty():
        out.append(_rx_frame(mon.recv_nowait(compact=False)))
    return out

def _snapshot(dut, k):
    return dict(
        rx_err_frames=int(getattr(dut, f"rx_err_frames_c{k}").value),
        rx_drop_frames=int(getattr(dut, f"rx_drop_frames_c{k}").value),
        rx_overflow=int(getattr(dut, f"rx_overflow_c{k}").value),
        rx_trunc=int(getattr(dut, f"rx_trunc_c{k}").value),
        tx_cpl_overflow=int(getattr(dut, f"tx_cpl_overflow_c{k}").value),
        quad_rx_events=int(getattr(dut, f"quad{k}_rx_reset_events").value),
        quad_tx_events=int(getattr(dut, f"quad{k}_tx_reset_events").value),
    )

class Watcher:

    def __init__(self, dut, preds):
        self.dut = dut
        self.preds = preds
        self.violations = []
        self.samples = 0
        self._task = None

    async def _run(self):
        while True:
            await RisingEdge(self.dut.seg_clk)
            self.samples += 1
            for name, fn in self.preds.items():
                try:
                    ok = fn()
                except Exception as e:
                    ok, name = False, f"{name} <unreadable: {e}>"
                if not ok:
                    self.violations.append((name, get_sim_time("ns")))
                    return

    def start(self):
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self):
        if self._task is not None:
            try:
                self._task.kill()
            except Exception:
                pass

    def assert_clean(self, what):
        assert self.samples > 0, \
            f"{what}: the watcher never sampled -- the test proves nothing. Check seg_clk."
        assert not self.violations, (
            f"{what}: ISOLATION VIOLATED after {self.samples} sampled seg_clk cycles: " +
            "; ".join(f"{n} at {t} ns" for n, t in self.violations))

def _isolation_preds(dut, victim):
    v = victim
    m_other = _group_mask(1 - v)
    return {
        f"quad{v}_rx_dp_reset stayed low":
            lambda: ((int(dut.quad_rx_dp_reset.value) >> v) & 1) == 0,
        f"quad{v}_tx_dp_reset stayed low":
            lambda: ((int(dut.quad_tx_dp_reset.value) >> v) & 1) == 0,
        f"c{v} stayed in XFER":
            lambda: int(getattr(dut, f"fsm_state_c{v}").value) == S_XFER,
        f"c{v} link_up stayed high":
            lambda: int(getattr(dut, f"link_up_c{v}").value) == 1,
        f"c{v} tx_rst stayed low":
            lambda: int(getattr(dut, f"tx_rst_c{v}").value) == 0,
        f"c{v} rx_rst stayed low":
            lambda: int(getattr(dut, f"rx_rst_c{v}").value) == 0,
        f"c{v} ctl_tx_enable stayed high":
            lambda: int(getattr(dut, f"ctl_tx_enable_c{v}").value) == 1,
        "no cross-client group-mask leak (sticky)":
            lambda: int(dut.xclient_mask_leak.value) == 0,
        f"mac_port_reset never touched c{v}'s group":
            lambda: (int(dut.mac_port_reset.value) & m_other) == 0,
    }

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns15_client_buses_are_independent(dut):
    t0 = _arm_wall("test_ns15_client_buses_are_independent", dut)
    random.seed(15)
    _start_clocks(dut)
    await _reset(dut)
    views = _views(dut)
    sinks = _seg_sinks(dut, views)
    srcs = _tx_sources(dut)
    await _bringup(dut)

    fr0 = _rand_frame(256)
    await srcs[0].send(fr0)
    got0, err0 = await with_timeout(sinks[0].recv(), AWAIT_US, "us")
    assert got0 == fr0, f"client 0 TX not byte-exact: {len(got0)} vs {len(fr0)} bytes"
    assert err0 == 0
    await ClockCycles(dut.seg_clk, 200)
    assert sinks[1].queue.empty(), \
        " VIOLATED: a frame sent on client 0 appeared on client 1's segmented bus"

    fr1 = _rand_frame(512)
    await srcs[1].send(fr1)
    got1, err1 = await with_timeout(sinks[1].recv(), AWAIT_US, "us")
    assert got1 == fr1, "client 1 TX not byte-exact"
    assert err1 == 0
    await ClockCycles(dut.seg_clk, 200)
    assert sinks[0].queue.empty(), \
        " VIOLATED: a frame sent on client 1 appeared on client 0's segmented bus"
    _report_rate("test_ns15_client_buses_are_independent", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns17_concurrent_rx_byte_exact_both(dut):
    t0 = _arm_wall("test_ns17_concurrent_rx_byte_exact_both", dut)
    random.seed(17)
    _start_clocks(dut)
    await _reset(dut)
    views = _views(dut)
    srcs = _seg_sources(dut, views)
    mons = _rx_monitors(dut)
    await _bringup(dut)

    sent = {0: [], 1: []}
    sizes = [64, 128, 129, 512, 1518]

    async def feed(k):
        for n in sizes:
            fr = bytes([0xA0 | k]) + _rand_frame(n - 1)
            sent[k].append(fr)
            await srcs[k].send(fr)
            await srcs[k].idle_cycles(random.randint(1, 6))

    t_a = cocotb.start_soon(feed(0))
    t_b = cocotb.start_soon(feed(1))
    await with_timeout(t_a, AWAIT_US, "us")
    await with_timeout(t_b, AWAIT_US, "us")
    await ClockCycles(dut.rx_clk, 4000)

    for k in CLIENTS:
        got = _drain(mons[k])
        assert len(got) == len(sent[k]), \
            f"client {k}: got {len(got)} RX frames, sent {len(sent[k])}"
        for i, (data, err) in enumerate(got):
            assert err == 0, f"client {k} frame {i}: unexpected error flag"
            assert data == sent[k][i], (
                f" VIOLATED: client {k} frame {i} not byte-exact "
                f"({len(data)} vs {len(sent[k][i])} bytes)")
            assert data[0] == (0xA0 | k), (
                f" VIOLATED: client {k} received a frame tagged for client {data[0] & 1} "
                f"-- the two RX paths are not independent")
    _report_rate("test_ns17_concurrent_rx_byte_exact_both", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns17_concurrent_tx_byte_exact_both(dut):
    t0 = _arm_wall("test_ns17_concurrent_tx_byte_exact_both", dut)
    random.seed(1717)
    _start_clocks(dut)
    await _reset(dut)
    views = _views(dut)
    sinks = _seg_sinks(dut, views)
    srcs = _tx_sources(dut)
    await _bringup(dut)

    sent = {0: [], 1: []}
    sizes = [64, 65, 256, 1500]

    async def feed(k):
        for n in sizes:
            fr = bytes([0xB0 | k]) + _rand_frame(n - 1)
            sent[k].append(fr)
            await srcs[k].send(fr)

    await with_timeout(cocotb.start_soon(feed(0)), AWAIT_US, "us")
    await with_timeout(cocotb.start_soon(feed(1)), AWAIT_US, "us")

    for k in CLIENTS:
        for i in range(len(sizes)):
            got, err = await with_timeout(sinks[k].recv(), AWAIT_US, "us")
            assert err == 0, f"client {k} TX frame {i}: unexpected seg err"
            assert got == sent[k][i], f" VIOLATED: client {k} TX frame {i} not byte-exact"
            assert got[0] == (0xB0 | k), \
                f" VIOLATED: client {k}'s TX carried client {got[0] & 1}'s frame"
    _report_rate("test_ns17_concurrent_tx_byte_exact_both", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns17_c0_overflow_and_tx_abort_do_not_disturb_c1(dut):
    t0 = _arm_wall("test_ns17_c0_overflow_and_tx_abort_do_not_disturb_c1", dut)
    random.seed(171)
    _start_clocks(dut, rx_mhz=50.0)
    await _reset(dut)
    views = _views(dut)
    srcs = _seg_sources(dut, views)
    tx_srcs = _tx_sources(dut)
    sinks = _seg_sinks(dut, views)
    mons = _rx_monitors(dut)
    await _bringup(dut)

    before = _snapshot(dut, 1)
    c1_sent = []
    c0_abort = {}

    async def blast_c0():
        for _ in range(64):
            await srcs[0].send(_rand_frame(1518))

    async def sparse_c1():
        for i in range(6):
            fr = bytes([0xC1]) + _rand_frame(255)
            c1_sent.append(fr)
            await srcs[1].send(fr)
            await srcs[1].idle_cycles(400)

    async def abort_c0_tx():
        fr = _rand_frame(300)
        tu = [0] * len(fr)
        tu[min(BYTE_LANES - 1, len(fr) - 1)] |= 1
        await tx_srcs[0].send(AxiStreamFrame(tdata=fr, tuser=tu))
        await tx_srcs[0].wait()
        c0_abort["frame"] = fr

    w = Watcher(dut, _isolation_preds(dut, victim=1)).start()
    ta = cocotb.start_soon(blast_c0())
    tb = cocotb.start_soon(sparse_c1())
    tc = cocotb.start_soon(abort_c0_tx())
    await with_timeout(ta, AWAIT_US, "us")
    await with_timeout(tb, AWAIT_US, "us")
    await with_timeout(tc, AWAIT_US, "us")
    await ClockCycles(dut.rx_clk, 8000)
    w.stop()

    assert int(dut.rx_overflow_c0.value) == 1, (
        "the stimulus DID NOT WORK: client 0 never overflowed, so this test proves nothing about "
        "isolation. Raise the c0 burst count or lower the shared rx_clk.")

    w.assert_clean(" (c0 overflow + TX abort)")

    after = _snapshot(dut, 1)
    assert after == before, f" VIOLATED: client 1's counters moved: {before} -> {after}"
    got = _drain(mons[1])
    assert len(got) == len(c1_sent), \
        f" VIOLATED: client 1 got {len(got)} of {len(c1_sent)} frames while c0 overflowed"
    for i, (data, err) in enumerate(got):
        assert err == 0 and data == c1_sent[i], \
            f" VIOLATED: client 1 frame {i} corrupted by client 0's overflow"

    assert "frame" in c0_abort, "the TX-abort half of the stimulus never completed"
    a_data, a_err = await with_timeout(sinks[0].recv(), AWAIT_US, "us")
    assert a_data == c0_abort["frame"], "client 0's aborted frame was not byte-exact "
    assert a_err == 1, \
        "the TX abort did not reach client 0's segmented EOP as tx_seg_err -- stimulus vacuous"
    assert sinks[1].queue.empty(), \
        " VIOLATED: client 0's aborted TX frame appeared on client 1's segmented bus"
    _report_rate("test_ns17_c0_overflow_and_tx_abort_do_not_disturb_c1", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns21_group_masks_disjoint_and_owned(dut):
    t0 = _arm_wall("test_ns21_group_masks_disjoint_and_owned", dut)
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    m0, m1 = _group_mask(0), _group_mask(1)
    assert (m0 & m1) == 0, (
        f"the VARIANTS THEMSELVES overlap: c0 mask {m0:#04x} (anchor {ANCHOR_C0}, {NPORTS_C0} port(s)) "
        f"and c1 mask {m1:#04x} (anchor {ANCHOR_C1}, {NPORTS_C1}) intersect -- fix the variant, not the RTL")

    for k in CLIENTS:
        mine, theirs = _group_mask(k), _group_mask(1 - k)
        getattr(dut, f"link_reset_req_c{k}").value = 1
        seen = 0
        for _ in range(64):
            await RisingEdge(dut.seg_clk)
            if int(getattr(dut, f"rx_datapath_reset_c{k}").value):
                seen = int(dut.mac_port_reset.value)
                break
        assert seen != 0, (
            f" VIOLATED: `link_reset_req_c{k}` never reached client {k}'s RX datapath reset, "
            f"so nothing below can be measured. This is the ONE request port.")
        assert seen & theirs == 0, (
            f" VIOLATED: a host RX datapath reset on client {k} put bits {seen:#04x} on the "
            f"shared MAC-port bus, intersecting client {1-k}'s group {theirs:#04x}")
        assert seen & mine == mine, (
            f" VIOLATED: client {k}'s reset covered {seen:#04x}, not its whole group "
            f"{mine:#04x} -- this is the 7/10 -> 20/20 defect, per client")
        assert ((int(dut.quad_rx_dp_reset.value) >> (1 - k)) & 1) == 0, \
            f" VIOLATED: resetting client {k} asserted quad {1-k}'s RX datapath reset"
        assert int(getattr(dut, f"link_reset_ack_c{k}").value) == 1, \
            f": client {k}'s acknowledgement must be a LEVEL, high while the reset is serviced"
        getattr(dut, f"link_reset_req_c{k}").value = 0
        for _ in range(RESET_CYC * 3):
            await RisingEdge(dut.seg_clk)
            if int(getattr(dut, f"rx_datapath_reset_c{k}").value) == 0 \
                    and int(getattr(dut, f"link_reset_ack_c{k}").value) == 0:
                break
        assert int(getattr(dut, f"link_reset_ack_c{k}").value) == 0, \
            f": client {k}'s reset never completed, so the next variant would start mid-reset"
        await ClockCycles(dut.seg_clk, 8)

    assert int(dut.xclient_mask_leak.value) == 0, \
        " VIOLATED: the sticky cross-client mask-leak flag is set"
    _report_rate("test_ns21_group_masks_disjoint_and_owned", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns21_simultaneous_realign_both_clients_recover(dut):
    t0 = _arm_wall("test_ns21_simultaneous_realign_both_clients_recover", dut)
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)
    q0, q1 = int(dut.quad0_rx_reset_events.value), int(dut.quad1_rx_reset_events.value)

    dut.gt_down_c0.value = 1
    dut.gt_down_c1.value = 1
    await ClockCycles(dut.seg_clk, 64)
    assert int(dut.fsm_state_c0.value) != S_XFER and int(dut.fsm_state_c1.value) != S_XFER

    dut.link_reset_req_c0.value = 1
    dut.link_reset_req_c1.value = 1
    for _ in range(RESET_CYC * 3):
        await RisingEdge(dut.seg_clk)
        if int(dut.link_reset_ack_c0.value) and int(dut.link_reset_ack_c1.value):
            break
    assert int(dut.link_reset_ack_c0.value) == 1 and int(dut.link_reset_ack_c1.value) == 1, \
        ": one or both clients never acknowledged the request, so no reset was serviced"
    dut.link_reset_req_c0.value = 0
    dut.link_reset_req_c1.value = 0
    await ClockCycles(dut.seg_clk, RESET_CYC * 2)
    dut.gt_down_c0.value = 0
    dut.gt_down_c1.value = 0

    for _ in range(6000):
        await RisingEdge(dut.seg_clk)
        if int(dut.fsm_state_c0.value) == S_XFER and int(dut.fsm_state_c1.value) == S_XFER:
            break
    assert int(dut.fsm_state_c0.value) == S_XFER, "client 0 did not recover"
    assert int(dut.fsm_state_c1.value) == S_XFER, "client 1 did not recover"
    assert int(dut.quad0_rx_reset_events.value) > q0, "client 0's quad reset never fired"
    assert int(dut.quad1_rx_reset_events.value) > q1, "client 1's quad reset never fired"
    assert int(dut.xclient_mask_leak.value) == 0, "cross-client mask leak during a dual re-align"
    _report_rate("test_ns21_simultaneous_realign_both_clients_recover", t0)

async def _ns22_body(dut, k, name):
    t0 = _arm_wall(name, dut)
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)
    q_tx_before = int(getattr(dut, f"quad{k}_tx_reset_events").value)
    q_rx_before = int(getattr(dut, f"quad{k}_rx_reset_events").value)

    assert not hasattr(dut, f"tx_datapath_reset_c{k}"), (
        f"/: `tx_datapath_reset_c{k}` is back. The GT TX datapath reset is the HOST's alone, "
        f"through the sequencer's pass-through; a second route re-creates the vendor exdes defect.")

    preds = {
        f"quad{k} TX datapath reset stayed low":
            lambda: ((int(dut.quad_tx_dp_reset.value) >> k) & 1) == 0,
        "the OTHER quad's TX datapath reset stayed low":
            lambda: ((int(dut.quad_tx_dp_reset.value) >> (1 - k)) & 1) == 0,
        f"c{k} host TX request stayed low (the stimulus must not touch it)":
            lambda: int(getattr(dut, f"host_tx_dp_req_c{k}").value) == 0,
    }
    w = Watcher(dut, preds).start()
    getattr(dut, f"gt_down_c{k}").value = 1
    await ClockCycles(dut.seg_clk, 64)
    assert int(getattr(dut, f"fsm_state_c{k}").value) != S_XFER, \
        f"client {k} never left XFER -- no alignment loss was produced"
    getattr(dut, f"link_reset_req_c{k}").value = 1
    for _ in range(RESET_CYC * 3):
        await RisingEdge(dut.seg_clk)
        if int(getattr(dut, f"link_reset_ack_c{k}").value):
            break
    assert int(getattr(dut, f"link_reset_ack_c{k}").value) == 1, \
        f": client {k} never acknowledged the request, so no reset was serviced"
    getattr(dut, f"link_reset_req_c{k}").value = 0
    await ClockCycles(dut.seg_clk, RESET_CYC * 2)
    getattr(dut, f"gt_down_c{k}").value = 0
    for _ in range(6000):
        await RisingEdge(dut.seg_clk)
        if int(getattr(dut, f"fsm_state_c{k}").value) == S_XFER:
            break
    await ClockCycles(dut.seg_clk, 64)
    w.stop()

    assert int(getattr(dut, f"quad{k}_rx_reset_events").value) > q_rx_before, (
        f"VACUOUS TEST: client {k}'s RX datapath reset never asserted, so 'TX stayed low' proves "
        f"nothing.  is about RX-ONLY, not about no reset at all.")
    w.assert_clean(f" (client {k})")
    assert int(getattr(dut, f"quad{k}_tx_reset_events").value) == q_tx_before, (
        f" VIOLATED: client {k}'s TX datapath reset asserted on a re-align "
        f"({q_tx_before} -> {int(getattr(dut, f'quad{k}_tx_reset_events').value)}). This is the "
        f"vendor exdes defect: a reset on one board drops its own TX and un-aligns the partner.")

    getattr(dut, f"host_tx_dp_req_c{k}").value = 1
    await ClockCycles(dut.seg_clk, 4)
    assert ((int(dut.quad_tx_dp_reset.value) >> k) & 1) == 1, (
        f"the  observation surface is DEAD: raising the host's TX request on client {k} did "
        f"not raise `quad_tx_dp_reset[{k}]`, so 'the TX reset stayed low' above measured nothing.")
    getattr(dut, f"host_tx_dp_req_c{k}").value = 0
    await ClockCycles(dut.seg_clk, 4)
    assert int(getattr(dut, f"quad{k}_tx_reset_events").value) == q_tx_before + 1, \
        f"client {k}'s TX reset event counter did not follow the host request it is derived from"
    _report_rate(name, t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns22_tx_dp_reset_never_on_realign_c0(dut):
    await _ns22_body(dut, 0, "test_ns22_tx_dp_reset_never_on_realign_c0")

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns22_tx_dp_reset_never_on_realign_c1(dut):
    await _ns22_body(dut, 1, "test_ns22_tx_dp_reset_never_on_realign_c1")

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns18_one_shared_clock_family(dut):
    t0 = _arm_wall("test_ns18_one_shared_clock_family", dut)
    _start_clocks(dut)
    await _reset(dut)
    assert set(_CLKS.keys()) == {"seg", "tx", "rx"}, \
        f": the harness started {sorted(_CLKS)} -- a second clock family would make every " \
        f"isolation test easier and meaningless"
    await _bringup(dut)
    for k in CLIENTS:
        assert int(getattr(dut, f"link_up_c{k}").value) == 1, \
            f": client {k} did not come up on the shared clock family"
    _report_rate("test_ns18_one_shared_clock_family", t0)

@cocotb.test(timeout_time=TEST_US, timeout_unit="us")
async def test_ns23_no_axi_face_at_the_client(dut):
    t0 = _arm_wall("test_ns23_no_axi_face_at_the_client", dut)
    _start_clocks(dut)
    await _reset(dut)
    leaked = [n for n in dir(dut) if n.startswith(("s_axil_", "s_axi_", "m_axi_"))]
    assert not leaked, (
        f": the 2-client harness exposes an AXI face {leaked} -- the per-client module must "
        f"not have one, or two masters onto the single DCMAC `s_axi` become possible")
    _report_rate("test_ns23_no_axi_face_at_the_client", t0)
