# ---------------------------------------------------------------------------
# File        : test_dcmac_link_sample.py
# Description : The sampler tests: it reads forever with no budget, it never writes, its
#               valid is low until the first read resolves, it publishes the fault nibble
#               it read, and no two reads are outstanding at once.
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
from cocotb.triggers import RisingEdge, ClockCycles, Timer

CLK_NS = 4

CYC_PER_US = int(os.environ.get("CYC_PER_US", "4"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "4"))
T_SAMPLE_MS = int(os.environ.get("T_SAMPLE_MS", "5"))
T_ERR_MS = int(os.environ.get("T_ERR_MS", "10"))
LINK_WDT_MS = int(os.environ.get("LINK_WDT_MS", "2000"))
N_BUS_ERR = int(os.environ.get("N_BUS_ERR", "4"))
LAT = int(os.environ.get("NIA_EXEC_LAT", "3"))

GAP_CYC = T_SAMPLE_MS * CYC_PER_MS
ERR_CYC = T_ERR_MS * CYC_PER_MS
WDT_CYC = LINK_WDT_MS * CYC_PER_MS

PAIR_CYC = 2 * (LAT + 4) + GAP_CYC
ROUND_CYC = WDT_CYC + 2 * PAIR_CYC + 64

print(f"NIA link_sample: CYC_PER_US={CYC_PER_US} CYC_PER_MS={CYC_PER_MS} "
      f"T_SAMPLE_MS={T_SAMPLE_MS} T_ERR_MS={T_ERR_MS} LINK_WDT_MS={LINK_WDT_MS} "
      f"N_BUS_ERR={N_BUS_ERR} LAT={LAT} "
      f"GAP_CYC={GAP_CYC} WDT_CYC={WDT_CYC} PAIR_CYC={PAIR_CYC} ROUND_CYC={ROUND_CYC}",
      flush=True)

A_ALIGN = 0xC04
A_FAULT = 0x144
ALIGN_MASK = 0x5

class Executor:
    def __init__(self, dut, lat=LAT):
        self.dut = dut
        self.lat = lat
        self.err = False
        self.align_word = 0x0
        self.fault_word = 0x0
        self.reads = []
        self.grants = []
        self.outstanding = 0
        self.max_outstanding = 0
        self.cyc = 0

    async def run(self):
        d = self.dut
        d.req_gnt.value = 0
        d.req_ack.value = 0
        d.ack_rdata.value = 0
        d.ack_aligned.value = 0
        d.ack_err.value = 0
        pend = []
        while True:
            await RisingEdge(d.clk)
            self.cyc += 1
            d.req_gnt.value = 0
            d.req_ack.value = 0

            for due, addr in pend:
                if self.cyc == due - 1:
                    if self.err:
                        d.ack_rdata.value = 0
                        d.ack_aligned.value = 0
                    else:
                        word = self.align_word if addr == A_ALIGN else self.fault_word
                        mask = ALIGN_MASK if addr == A_ALIGN else 0
                        d.ack_rdata.value = word
                        d.ack_aligned.value = 1 if (word & mask) == mask else 0

            keep = []
            for due, addr in pend:
                if self.cyc >= due:
                    self.outstanding -= 1
                    if self.err:
                        d.ack_err.value = 1
                        d.ack_aligned.value = 0
                        d.ack_rdata.value = 0
                    else:
                        word = self.align_word if addr == A_ALIGN else self.fault_word
                        mask = ALIGN_MASK if addr == A_ALIGN else 0
                        d.ack_err.value = 0
                        d.ack_aligned.value = 1 if (word & mask) == mask else 0
                        d.ack_rdata.value = word
                    d.req_ack.value = 1
                    self.reads.append((self.cyc, addr, int(d.ack_rdata.value),
                                       int(d.ack_err.value)))
                else:
                    keep.append((due, addr))
            pend = keep

            if int(d.req_valid.value) == 1 and self.outstanding == 0:
                addr = int(d.req_addr.value)
                self.grants.append((self.cyc, addr, int(d.req_write.value)))
                d.req_gnt.value = 1
                self.outstanding += 1
                self.max_outstanding = max(self.max_outstanding, self.outstanding)
                pend.append((self.cyc + self.lat, addr))

    def align_reads(self):
        return [r[0] for r in self.reads if r[1] == A_ALIGN]

    def tail(self, n=8):
        return [(c, 'ALIGN' if a == A_ALIGN else 'FAULT', hex(w), e)
                for c, a, w, e in self.reads[-n:]]

    def set_aligned(self, up: bool):
        self.align_word = ALIGN_MASK if up else 0x0

_TASKS = []

def _spawn(coro):
    t = cocotb.start_soon(coro)
    _TASKS.append(t)
    return t

def _kill_all():
    for t in _TASKS:
        try:
            t.kill()
        except Exception:
            pass
    _TASKS.clear()

async def _quiesce(dut):
    _kill_all()
    dut.req_gnt.value = 0
    dut.req_ack.value = 0
    dut.ack_rdata.value = 0
    dut.ack_aligned.value = 0
    dut.ack_err.value = 0
    await Timer(2 * CLK_NS, units="ns")

async def setup(dut, wdt_ms=0, enable=1):
    await _quiesce(dut)
    _spawn(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rstn.value = 0
    dut.enable.value = 0
    dut.wdt_ms.value = wdt_ms
    dut.reset_ack.value = 0
    ex = Executor(dut)
    _spawn(ex.run())
    await ClockCycles(dut.clk, 8)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 4)
    dut.enable.value = enable
    return ex

async def ack_resets(dut, log=None):
    while True:
        await RisingEdge(dut.clk)
        if int(dut.reset_req.value) == 1:
            if log is not None:
                log.append(1)
            dut.reset_ack.value = 1
            await RisingEdge(dut.clk)
            dut.reset_ack.value = 0

async def _await_value(dut, handle, want, limit):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if int(handle.value) == want:
            return True
    return False

@cocotb.test()
async def test_ns62_reads_forever_with_no_budget(dut):
    ex = await setup(dut)
    ex.set_aligned(False)
    _spawn(ack_resets(dut))
    await ClockCycles(dut.clk, 30 * PAIR_CYC)
    n1 = len(ex.align_reads())
    await ClockCycles(dut.clk, 30 * PAIR_CYC)
    n2 = len(ex.align_reads())
    assert n1 > 5, f"sampler stopped early: only {n1} alignment reads"
    assert (n2 - n1) > 5, (
        f"sampler ran out of patience: {n1} reads in the first stretch, {n2 - n1} in the second. "
        " forbids a budget."
    )

@cocotb.test()
async def test_ns62_never_writes(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    await ClockCycles(dut.clk, 10 * PAIR_CYC)
    assert len(ex.grants) > 4, "no grants observed"
    bad = [(c, hex(a)) for c, a, w in ex.grants if w != 0]
    assert not bad, f": the sampler issued writes at {bad}"

@cocotb.test()
async def test_ns63_valid_is_low_until_the_first_read_resolves(dut):
    _kill_all()
    _spawn(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rstn.value = 0
    dut.enable.value = 0
    dut.wdt_ms.value = 0
    dut.reset_ack.value = 0
    dut.req_gnt.value = 0
    dut.req_ack.value = 0
    dut.ack_rdata.value = 0
    dut.ack_aligned.value = 0
    dut.ack_err.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 4)
    dut.enable.value = 1
    await ClockCycles(dut.clk, 4 * WDT_CYC)
    assert int(dut.valid.value) == 0, ": `valid` rose without a resolved read"
    assert int(dut.window_running.value) == 0, (
        ": the window started before the first resolved read. A slow first read must not look "
        "like a fault."
    )
    assert int(dut.reset_req.value) == 0, "a reset was requested before any observation existed"

@cocotb.test()
async def test_ns63_publishes_the_fault_nibble_from_rdata(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    ex.fault_word = 0xA

    got = await _await_value(dut, dut.fault, 0xA, 20 * PAIR_CYC)
    assert got, (
        f"fault = {int(dut.fault.value):#x}, expected 0xA within {20 * PAIR_CYC} cycles. "
        f"Last verdicts delivered: {ex.tail()}")
    assert int(dut.recv_local_fault.value) == 1, "bit 3 must surface as recv_local_fault"
    assert int(dut.remote_fault.value) == 0, "bit 0 must surface as remote_fault"

    ex.fault_word = 0x1
    got = await _await_value(dut, dut.fault, 0x1, 20 * PAIR_CYC)
    assert got, (
        f"fault = {int(dut.fault.value):#x}, expected 0x1. Last verdicts delivered: {ex.tail()}")
    assert int(dut.remote_fault.value) == 1, "remote_fault did not follow bit 0"
    assert int(dut.recv_local_fault.value) == 0

@cocotb.test()
async def test_ns64_no_two_reads_are_outstanding_at_once(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    await ClockCycles(dut.clk, 20 * PAIR_CYC)
    assert ex.max_outstanding <= 1, (
        f": {ex.max_outstanding} transactions were outstanding at once"
    )

@cocotb.test()
async def test_ns64_is_self_paced_not_periodic(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    ex.lat = GAP_CYC * 3
    await ClockCycles(dut.clk, 12 * (2 * ex.lat + GAP_CYC + 16))
    cs = ex.align_reads()
    assert len(cs) >= 3, f"too few reads to judge pacing: {len(cs)}"
    deltas = [b - a for a, b in zip(cs, cs[1:])]
    assert min(deltas) >= GAP_CYC, (
        f": reads {min(deltas)} cycles apart with a gap of {GAP_CYC} - the cadence was overrun"
    )
    assert ex.max_outstanding <= 1

@cocotb.test()
async def test_ns65_cadence_matches_the_gap_parameter(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    await ClockCycles(dut.clk, 24 * PAIR_CYC)
    cs = ex.align_reads()
    assert len(cs) >= 4
    deltas = [b - a for a, b in zip(cs, cs[1:])]
    lo, hi = GAP_CYC + 2, GAP_CYC + 2 * (LAT + 6)
    assert all(lo <= d <= hi for d in deltas), (
        f"pair period {deltas} outside [{lo},{hi}] derived from T_SAMPLE_MS={T_SAMPLE_MS} and "
        f"LAT={LAT}"
    )

@cocotb.test()
async def test_ns66_an_errored_read_publishes_nothing(dut):
    log = []
    ex = await setup(dut)
    ex.set_aligned(True)
    _spawn(ack_resets(dut, log))
    await ClockCycles(dut.clk, 8 * PAIR_CYC)
    assert int(dut.aligned.value) == 1, "did not come up aligned"
    ex.err = True
    await ClockCycles(dut.clk, (N_BUS_ERR - 1) * (ERR_CYC + LAT + 8))
    assert int(dut.aligned.value) == 1, (
        ": an errored read changed the published alignment. A wedged bus is not a dead cable."
    )
    assert not log, f"errored reads requested {len(log)} resets"

@cocotb.test()
async def test_ns69_window_does_not_run_while_aligned(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    log = []
    _spawn(ack_resets(dut, log))
    await ClockCycles(dut.clk, 4 * WDT_CYC)
    assert int(dut.window_running.value) == 0, "the window ran while the port was aligned"
    assert not log, f"an aligned port requested {len(log)} resets"

@cocotb.test()
async def test_ns69_expiry_requests_a_reset_and_reloads(dut):
    ex = await setup(dut)
    ex.set_aligned(False)
    log = []
    _spawn(ack_resets(dut, log))
    await ClockCycles(dut.clk, 5 * ROUND_CYC)
    assert len(log) >= 3, f"only {len(log)} resets in 5 windows - the window did not reload"
    assert len(log) <= 8, f"{len(log)} resets in 5 windows - the window is shorter than configured"

@cocotb.test()
async def test_ns69_zero_ms_means_the_parameter(dut):
    ex = await setup(dut, wdt_ms=0)
    ex.set_aligned(False)
    log = []
    _spawn(ack_resets(dut, log))
    await ClockCycles(dut.clk, WDT_CYC // 2)
    assert not log, "a zero window register made the sampler a reset generator"

@cocotb.test()
async def test_ns70_twelve_windows_down_then_up_is_taken(dut):
    ex = await setup(dut)
    ex.set_aligned(False)
    log = []
    _spawn(ack_resets(dut, log))
    await ClockCycles(dut.clk, 12 * ROUND_CYC)
    n_before = len(log)
    assert n_before >= 6, f"only {n_before} escalations over 12 windows"
    ex.set_aligned(True)
    await ClockCycles(dut.clk, 4 * PAIR_CYC)
    assert int(dut.aligned.value) == 1, (
        ": a link that came back after twelve failed windows was not taken"
    )
    assert int(dut.ever_aligned.value) == 1
    await ClockCycles(dut.clk, 3 * WDT_CYC)
    assert len(log) == n_before, "resets continued after the link came back"

@cocotb.test()
async def test_ns74_bus_stuck_after_n_consecutive_errors(dut):
    ex = await setup(dut)
    ex.set_aligned(True)
    _spawn(ack_resets(dut))
    await ClockCycles(dut.clk, 6 * PAIR_CYC)
    assert int(dut.bus_stuck.value) == 0
    ex.err = True
    await ClockCycles(dut.clk, (N_BUS_ERR + 2) * (ERR_CYC + LAT + 8))
    assert int(dut.bus_stuck.value) == 1, (
        f": bus_stuck did not rise after {N_BUS_ERR} consecutive unresolved reads"
    )

@cocotb.test()
async def test_ns74_one_resolved_read_clears_the_bus_error_run(dut):
    if N_BUS_ERR < 2:
        return
    ex = await setup(dut)
    ex.set_aligned(True)
    _spawn(ack_resets(dut))
    await ClockCycles(dut.clk, 4 * PAIR_CYC)
    for _ in range(3 * N_BUS_ERR):
        ex.err = True
        await ClockCycles(dut.clk, ERR_CYC + LAT + 10)
        ex.err = False
        await ClockCycles(dut.clk, PAIR_CYC + 10)
        assert int(dut.bus_stuck.value) == 0, (
            ": bus_stuck rose although the errors were never consecutive"
        )

@cocotb.test()
async def test_ns74_a_dead_link_never_raises_bus_stuck(dut):
    ex = await setup(dut)
    ex.set_aligned(False)
    _spawn(ack_resets(dut))
    await ClockCycles(dut.clk, 10 * ROUND_CYC)
    assert int(dut.bus_stuck.value) == 0, (
        ": a dead link raised bus_stuck, which would re-run configuration for the whole MAC - "
        "an escalation with a larger scope than its fault."
    )
