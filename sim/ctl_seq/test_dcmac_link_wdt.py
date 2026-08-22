# ---------------------------------------------------------------------------
# File        : test_dcmac_link_wdt.py
# Description : The link watchdog tests: it escalates every window forever, an aligned
#               poll reloads it, no state stops and a late link is taken, the fault
#               diagnosis is evidence and not control, and the window follows the runtime
#               register.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import time

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

CLK_NS = 4

CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
LINK_WDT_MS = int(os.environ.get("LINK_WDT_MS", "20"))
LINK_CONFIRM_N = int(os.environ.get("LINK_CONFIRM_N", "2"))
ESC_MAX_STAGE = int(os.environ.get("ESC_MAX_STAGE", "3"))
T_RXDP_MS = int(os.environ.get("T_RXDP_MS", "5"))
T_SETTLE_MS = int(os.environ.get("T_SETTLE_MS", "2"))
T_ERR_MS = int(os.environ.get("T_ERR_MS", "2"))

WDT_CYC = LINK_WDT_MS * CYC_PER_MS
RXDP_CYC = T_RXDP_MS * CYC_PER_MS
STL_CYC = T_SETTLE_MS * CYC_PER_MS
ERR_CYC = T_ERR_MS * CYC_PER_MS

ESC_CYC = 2 * RXDP_CYC + STL_CYC + 64
ROUND_CYC = WDT_CYC + ESC_CYC + 64
TIMEOUT_US = float(os.environ.get("NIA_WDT_TEST_US", f"{40 * ROUND_CYC * CLK_NS / 1000.0:.0f}"))

print(f"NIA_N18 link_wdt: CYC_PER_MS={CYC_PER_MS} LINK_WDT_MS={LINK_WDT_MS} "
      f"LINK_CONFIRM_N={LINK_CONFIRM_N} ESC_MAX_STAGE={ESC_MAX_STAGE} "
      f"T_RXDP_MS={T_RXDP_MS} T_SETTLE_MS={T_SETTLE_MS} "
      f"WDT_CYC={WDT_CYC} ESC_CYC={ESC_CYC} ROUND_CYC={ROUND_CYC} "
      f"-> timeout {TIMEOUT_US:.0f} us", flush=True)

class Executor:
    def __init__(self, dut, lat=3):
        self.dut = dut
        self.lat = lat
        self.polls = 0
        self.aligned = True
        self.err = False
        self.stamps = []

    async def run(self, cyc):
        d = self.dut
        d.poll_gnt.value = 0
        d.poll_ack.value = 0
        d.poll_aligned.value = 0
        d.poll_err.value = 0
        while True:
            await RisingEdge(d.clk)
            d.poll_gnt.value = 0
            d.poll_ack.value = 0
            if int(d.poll_req.value):
                d.poll_gnt.value = 1
                await RisingEdge(d.clk)
                d.poll_gnt.value = 0
                for _ in range(self.lat):
                    await RisingEdge(d.clk)
                d.poll_ack.value = 1
                d.poll_aligned.value = 0 if self.err else (1 if self.aligned else 0)
                d.poll_err.value = 1 if self.err else 0
                self.polls += 1
                self.stamps.append(cyc())
                await RisingEdge(d.clk)
                d.poll_ack.value = 0
                d.poll_err.value = 0
                d.poll_aligned.value = 0

class Cyc:
    def __init__(self, dut):
        self.n = 0
        self.dut = dut

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            self.n += 1

    def __call__(self):
        return self.n

async def start(dut, aligned=True, lat=3, wdt_ms=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rstn.value = 0
    dut.enable.value = 0
    dut.wdt_ms.value = wdt_ms
    c = Cyc(dut)
    cocotb.start_soon(c.run())
    ex = Executor(dut, lat=lat)
    ex.aligned = aligned
    cocotb.start_soon(ex.run(c))
    await ClockCycles(dut.clk, 8)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 4)
    dut.enable.value = 1
    return ex, c

async def wait_for(dut, pred, limit, what):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if pred():
            return True
    raise AssertionError(f"{what}: not satisfied within {limit} cycles")

async def hold(dut, cyc, pred, what):
    for _ in range(cyc):
        await RisingEdge(dut.clk)
        assert pred(), what

def up(dut):
    return int(dut.link_up.value)

def live(dut):
    return int(dut.link_live.value)

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns54_escalates_every_window_forever(dut):
    ex, cyc = await start(dut, aligned=False)
    n0 = int(dut.esc_count.value)
    await wait_for(dut, lambda: int(dut.esc_count.value) >= n0 + 12,
                   14 * ROUND_CYC, "twelve escalations in twelve windows")
    assert int(dut.esc_count.value) >= 12, "escalation count did not advance"
    assert int(dut.link_up.value) == 0
    n1 = int(dut.esc_count.value)
    await wait_for(dut, lambda: int(dut.esc_count.value) > n1, 3 * ROUND_CYC,
                   "escalation continues after twelve windows")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns54_aligned_poll_reloads_and_does_not_escalate(dut):
    ex, cyc = await start(dut, aligned=True)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link comes up")
    n0 = int(dut.esc_count.value)
    await hold(dut, 6 * WDT_CYC,
               lambda: int(dut.esc_count.value) == n0 and up(dut) == 1 and live(dut) == 1,
               "an aligned link neither escalates nor drops")
    assert ex.polls >= 5, f"the window should keep polling; only {ex.polls} polls in 6 windows"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns55_no_state_stops_and_a_late_link_is_taken(dut):
    ex, cyc = await start(dut, aligned=False)
    await wait_for(dut, lambda: int(dut.esc_count.value) >= 12, 14 * ROUND_CYC,
                   "twelve windows of outage")
    ex.aligned = True
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC,
                   "the link is taken after an arbitrarily long outage")
    assert int(dut.fault_diag.value) == 1, (
        "fault_diag must remain latched: it is the evidence that escalations happened")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns55_fault_diag_is_evidence_not_control(dut):
    ex, cyc = await start(dut, aligned=False)
    await wait_for(dut, lambda: int(dut.fault_diag.value) == 1, 3 * ROUND_CYC, "fault_diag latches")
    n0 = int(dut.esc_count.value)
    await wait_for(dut, lambda: int(dut.esc_count.value) >= n0 + 3, 5 * ROUND_CYC,
                   "escalation continues with fault_diag set")
    ex.aligned = True
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "recovery with fault_diag set")
    assert int(dut.fault_diag.value) == 1, "fault_diag must not self-clear"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", skip=(ESC_MAX_STAGE < 2))
async def test_ns58_stage_order_is_tx_then_rx_with_a_settle(dut):
    ex, cyc = await start(dut, aligned=False)
    await wait_for(dut, lambda: int(dut.esc_rx_dp_reset.value) == 1, 3 * ROUND_CYC, "stage 1 runs")
    await wait_for(dut, lambda: int(dut.esc_gt_tx_reset.value) == 1, 4 * ROUND_CYC, "stage 2 TX")
    t_tx = cyc()
    assert int(dut.esc_gt_rx_reset.value) == 0, (
        " VIOLATED: the GT RX half is asserted at the same time as the TX half. TX first, then "
        "RX - and one bit driving both is the vendor defect this clause exists to keep out")
    await wait_for(dut, lambda: int(dut.esc_gt_tx_reset.value) == 0, 2 * RXDP_CYC + 64,
                   "the TX half releases")
    t_txrel = cyc()
    assert int(dut.esc_gt_rx_reset.value) == 0, "the RX half must wait for the settle"
    await wait_for(dut, lambda: int(dut.esc_gt_rx_reset.value) == 1, 2 * STL_CYC + 64,
                   "the RX half asserts after the settle")
    t_rx = cyc()
    assert t_rx > t_txrel, "the RX assert must follow the TX release"
    assert (t_rx - t_txrel) >= STL_CYC - 4, (
        f"the settle was {t_rx - t_txrel} cycles, expected >= {STL_CYC}")
    assert (t_txrel - t_tx) >= RXDP_CYC - 4, (
        f"the TX hold was {t_txrel - t_tx} cycles, expected >= {RXDP_CYC}")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", skip=(ESC_MAX_STAGE < 3))
async def test_ns58_stages_advance_and_the_top_stage_repeats(dut):
    ex, cyc = await start(dut, aligned=False)
    seen = []
    prev = 0
    for _ in range(12 * ROUND_CYC):
        await RisingEdge(dut.clk)
        s = int(dut.esc_stage.value)
        if s != 0 and prev == 0:
            seen.append(s)
        prev = s
        if len(seen) >= 4:
            break
    assert seen[:3] == [1, 2, 3], f"stages must advance 1,2,3 - saw {seen}"
    assert len(seen) >= 4 and seen[3] == 3, (
        f"the top stage must repeat rather than stop or wrap - saw {seen}")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us", skip=(ESC_MAX_STAGE != 1))
async def test_ns58_esc_max_stage_1_is_the_rx_only_control(dut):
    ex, cyc = await start(dut, aligned=False)
    await wait_for(dut, lambda: int(dut.esc_count.value) >= 5, 7 * ROUND_CYC, "five escalations")
    await hold(dut, 2 * ROUND_CYC,
               lambda: int(dut.esc_gt_tx_reset.value) == 0
               and int(dut.esc_gt_rx_reset.value) == 0
               and int(dut.esc_bringup_req.value) == 0,
               "at ESC_MAX_STAGE=1 no GT reset and no bring-up request may ever be asserted")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns59_window_follows_the_runtime_register(dut):
    ex, cyc = await start(dut, aligned=True, wdt_ms=LINK_WDT_MS)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link up")
    ex.stamps.clear()
    await ClockCycles(dut.clk, 4 * WDT_CYC)
    per1 = [b - a for a, b in zip(ex.stamps, ex.stamps[1:])]
    assert per1, "no polls were observed"
    m1 = sum(per1) / len(per1)
    dut.wdt_ms.value = 2 * LINK_WDT_MS
    await ClockCycles(dut.clk, 2 * WDT_CYC)
    ex.stamps.clear()
    await ClockCycles(dut.clk, 8 * WDT_CYC)
    per2 = [b - a for a, b in zip(ex.stamps, ex.stamps[1:])]
    assert per2, "no polls after the register was changed"
    m2 = sum(per2) / len(per2)
    assert abs(m1 - WDT_CYC) < 0.15 * WDT_CYC, f"period {m1:.0f} != {WDT_CYC} at wdt_ms={LINK_WDT_MS}"
    assert m2 > 1.6 * m1, (
        f"doubling wdt_ms must roughly double the period: {m1:.0f} -> {m2:.0f}")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns59_zero_means_the_parameter(dut):
    ex, cyc = await start(dut, aligned=True, wdt_ms=0)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link up with wdt_ms = 0")
    ex.stamps.clear()
    await ClockCycles(dut.clk, 4 * WDT_CYC)
    per = [b - a for a, b in zip(ex.stamps, ex.stamps[1:])]
    assert per, "no polls at wdt_ms = 0"
    m = sum(per) / len(per)
    assert abs(m - WDT_CYC) < 0.15 * WDT_CYC, (
        f"at wdt_ms = 0 the period must be the parameter ({WDT_CYC}), measured {m:.0f}")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns60_recovery_costs_one_window_not_a_poll_loop(dut):
    ex, cyc = await start(dut, aligned=True)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link up")
    ex.aligned = False
    await wait_for(dut, lambda: up(dut) == 0, 4 * ROUND_CYC, "the link drops")
    ex.aligned = True
    t0 = cyc()
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "the link is republished")
    dt = cyc() - t0
    bound = WDT_CYC + ESC_CYC + 4 * ERR_CYC + 256
    assert dt <= bound, (
        f"recovery took {dt} cycles; 's arithmetic allows {bound} "
        f"(one window {WDT_CYC} + one escalation {ESC_CYC}). A larger number means a poll loop "
        f"crept back onto the supervisory path")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns61_rise_publishes_on_the_first_aligned_poll(dut):
    ex, cyc = await start(dut, aligned=False)
    await wait_for(dut, lambda: int(dut.esc_count.value) >= 2, 4 * ROUND_CYC, "two windows down")
    ex.aligned = True
    p0 = ex.polls
    await wait_for(dut, lambda: up(dut) == 1, 3 * ROUND_CYC, "the rise is published")
    assert ex.polls - p0 <= 2, (
        f"the rise took {ex.polls - p0} polls to publish;  allows the first ALIGNED one "
        f"(the +1 tolerance covers a poll already in flight when the model changed)")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ns61_fall_is_debounced_but_escalation_is_not(dut):
    ex, cyc = await start(dut, aligned=True)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link up")
    n0 = int(dut.esc_count.value)
    ex.aligned = False
    await wait_for(dut, lambda: int(dut.esc_count.value) == n0 + 1, 3 * ROUND_CYC,
                   "the first unaligned window escalates")
    if LINK_CONFIRM_N >= 2:
        assert up(dut) == 1, (
            " VIOLATED: one unaligned poll dropped the report at LINK_CONFIRM_N >= 2")
        assert live(dut) == 0, "the LIVE view must fall on the first unaligned poll"
    ex.aligned = True
    await wait_for(dut, lambda: live(dut) == 1, 3 * ROUND_CYC, "the live view returns")
    assert up(dut) == 1, "the report never fell, so it cannot have risen again"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_err_poll_changes_no_view_and_does_not_escalate(dut):
    ex, cyc = await start(dut, aligned=True)
    await wait_for(dut, lambda: up(dut) == 1, 4 * ROUND_CYC, "link up")
    n0 = int(dut.esc_count.value)
    ex.err = True
    await ClockCycles(dut.clk, 6 * (ERR_CYC + 64))
    assert up(dut) == 1 and live(dut) == 1, (
        "an errored poll must not move a published view - it is not a link verdict")
    assert int(dut.esc_count.value) == n0, (
        "an errored poll must not escalate: that would reset a healthy link because a bus wedged")
    ex.err = False
    await hold(dut, 2 * WDT_CYC, lambda: up(dut) == 1, "the link survives the bus recovering")
