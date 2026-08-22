# ---------------------------------------------------------------------------
# File        : test_dcmac_axil_exec.py
# Description : The executor and arbiter tests: one transaction at a time, the priority
#               requester wins, round robin stays fair under saturation, a grant is one
#               cycle and not a lease, and an acknowledgement goes only to the granted
#               requester.
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
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

CLK_NS = 4
N_REQ = int(os.environ.get("N_REQ", "3"))
RR_START = int(os.environ.get("RR_START", "1"))
AW = int(os.environ.get("AW", "20"))
TMO_CYC = int(os.environ.get("TMO_CYC", "256"))
BAD_MAGIC = 0xDEADC0DE

TIMEOUT_US = float(os.environ.get("NIA_EXEC_TEST_US", "20000"))

print(f"NIA_N18 axil_exec: N_REQ={N_REQ} RR_START={RR_START} TMO_CYC={TMO_CYC} "
      f"-> timeout {TIMEOUT_US:.0f} us", flush=True)

class Slave:

    def __init__(self, dut):
        self.dut = dut
        self.rdata = 0x00000005
        self.rresp = 0
        self.bresp = 0
        self.answer = True
        self.reads = []
        self.writes = []
        self.inflight_max = 0

    async def _hs(self, sig, limit=64):
        for _ in range(limit):
            await RisingEdge(self.dut.clk)
            if int(self.dut.rstn.value) == 0:
                return False
            if int(sig.value):
                return True
        return False

    async def run(self):
        d = self.dut
        d.m_axil_awready.value = 0
        d.m_axil_wready.value = 0
        d.m_axil_bvalid.value = 0
        d.m_axil_bresp.value = 0
        d.m_axil_arready.value = 0
        d.m_axil_rvalid.value = 0
        d.m_axil_rdata.value = 0
        d.m_axil_rresp.value = 0
        aw = w = ar = False
        while True:
            await RisingEdge(d.clk)
            n = int(d.m_axil_arvalid.value) + int(d.m_axil_awvalid.value)
            self.inflight_max = max(self.inflight_max, n)
            d.m_axil_awready.value = 0
            d.m_axil_wready.value = 0
            d.m_axil_arready.value = 0
            d.m_axil_bvalid.value = 0
            d.m_axil_rvalid.value = 0
            if int(d.rstn.value) == 0:
                aw = w = ar = False
                continue
            if not self.answer:
                continue
            if int(d.m_axil_awvalid.value) and not aw:
                d.m_axil_awready.value = 1
                aw = True
            if int(d.m_axil_wvalid.value) and not w:
                d.m_axil_wready.value = 1
                w = True
                self.writes.append((int(d.m_axil_awaddr.value), int(d.m_axil_wdata.value)))
            if aw and w:
                await RisingEdge(d.clk)
                d.m_axil_awready.value = 0
                d.m_axil_wready.value = 0
                d.m_axil_bresp.value = self.bresp
                d.m_axil_bvalid.value = 1
                await self._hs(d.m_axil_bready)
                await RisingEdge(d.clk)
                d.m_axil_bvalid.value = 0
                aw = w = False
            if int(d.m_axil_arvalid.value) and not ar:
                d.m_axil_arready.value = 1
                self.reads.append(int(d.m_axil_araddr.value))
                await RisingEdge(d.clk)
                d.m_axil_arready.value = 0
                d.m_axil_rdata.value = self.rdata
                d.m_axil_rresp.value = self.rresp
                d.m_axil_rvalid.value = 1
                await self._hs(d.m_axil_rready)
                await RisingEdge(d.clk)
                d.m_axil_rvalid.value = 0

class Reqs:

    def __init__(self, dut):
        self.dut = dut
        self.n = N_REQ
        self._valid = 0
        self._write = 0
        self._addr = [0] * N_REQ
        self._mask = [0] * N_REQ
        self._wdata = [0] * N_REQ
        self._flush()

    def _pack(self, lst, w):
        v = 0
        for i, x in enumerate(lst):
            v |= (x & ((1 << w) - 1)) << (i * w)
        return v

    def _flush(self):
        self.dut.req_valid.value = self._valid
        self.dut.req_write.value = self._write
        self.dut.req_addr.value = self._pack(self._addr, AW)
        self.dut.req_mask.value = self._pack(self._mask, 32)
        self.dut.req_wdata.value = self._pack(self._wdata, 32)

    def setup(self, i, addr=0x1000, mask=0x5, wdata=0, write=0):
        self._addr[i] = addr
        self._mask[i] = mask
        self._wdata[i] = wdata
        self._write = (self._write | (1 << i)) if write else (self._write & ~(1 << i))
        self._flush()

    def assert_(self, i, on=True):
        self._valid = (self._valid | (1 << i)) if on else (self._valid & ~(1 << i))
        self._flush()

_TASKS = []

def _kill_leftovers():
    while _TASKS:
        t = _TASKS.pop()
        try:
            t.kill()
        except Exception:
            pass

async def start(dut):
    _kill_leftovers()
    _TASKS.append(cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start()))
    dut.rstn.value = 0
    r = Reqs(dut)
    s = Slave(dut)
    _TASKS.append(cocotb.start_soon(s.run()))
    await ClockCycles(dut.clk, 6)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 2)
    return r, s

def gnt(dut, i):
    return (int(dut.req_gnt.value) >> i) & 1

def ack(dut, i):
    return (int(dut.req_ack.value) >> i) & 1

async def await_ack(dut, i, limit=4000):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if ack(dut, i):
            await RisingEdge(dut.clk)
            return True
    return False

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_one_transaction_at_a_time(dut):
    r, s = await start(dut)
    for i in range(N_REQ):
        r.setup(i, addr=0x1000 + 0x40 * i)
        r.assert_(i)
    await ClockCycles(dut.clk, 600)
    assert s.inflight_max <= 1, (
        f"two transactions were in flight at once (max {s.inflight_max}).  is a property of "
        f"this module, not of the bus")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_priority_requester_wins(dut):
    if RR_START < 1:
        return
    r, s = await start(dut)
    for i in range(N_REQ):
        r.setup(i, addr=0x2000 + 0x40 * i)
    r.assert_(1)
    r.assert_(0)
    first = None
    for _ in range(400):
        await RisingEdge(dut.clk)
        await ReadOnly()
        for i in range(N_REQ):
            if gnt(dut, i) and first is None:
                first = i
        if first is not None:
            break
    assert first == 0, f"the priority requester must be granted first, saw requester {first}"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_round_robin_is_fair_under_saturation(dut):
    if N_REQ - RR_START < 2:
        return
    r, s = await start(dut)
    a, b = RR_START, RR_START + 1
    r.setup(a, addr=0x3000)
    r.setup(b, addr=0x3040)
    r.assert_(a)
    r.assert_(b)
    counts = {a: 0, b: 0}
    for _ in range(4000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        for i in (a, b):
            if gnt(dut, i):
                counts[i] += 1
    assert counts[a] >= 3 and counts[b] >= 3, (
        f"round robin is not fair under saturation: {counts}")
    assert abs(counts[a] - counts[b]) <= 1, (
        f"round robin must alternate one transaction each: {counts}")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_grant_is_one_cycle_and_not_a_lease(dut):
    r, s = await start(dut)
    i = RR_START if RR_START < N_REQ else 0
    r.setup(i, addr=0x4000)
    r.assert_(i)
    seen = 0
    for _ in range(600):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if gnt(dut, i):
            seen += 1
            await RisingEdge(dut.clk)
            await ReadOnly()
            assert gnt(dut, i) == 0, "the grant was held for more than one cycle"
            break
    assert seen == 1, "no grant was observed"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_ack_goes_only_to_the_granted_requester(dut):
    if N_REQ - RR_START < 2:
        return
    r, s = await start(dut)
    a, b = RR_START, RR_START + 1
    r.setup(a, addr=0x5000)
    r.setup(b, addr=0x5040)
    r.assert_(a)
    assert await await_ack(dut, a), "requester a never got its verdict"
    assert ack(dut, b) == 0, "requester b was acked for a transaction it never requested"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_aligned_is_computed_from_the_mask(dut):
    r, s = await start(dut)
    i = RR_START if RR_START < N_REQ else 0
    r.setup(i, addr=0x6000, mask=0x5)
    s.rdata = 0x00000107
    r.assert_(i)
    assert await await_ack(dut, i)
    print("NIA_DIAG aligned-test: rdata=0x%08x aligned=%d err=%d cur_req=%d reads=%s"
          % (int(dut.ack_rdata.value), int(dut.ack_aligned.value), int(dut.ack_err.value),
             int(dut.cur_req.value), [hex(x) for x in s.reads[-3:]]), flush=True)
    assert int(dut.ack_aligned.value) == 1 and int(dut.ack_err.value) == 0, (
        "0x107 & 0x5 == 0x5 - got rdata=0x%08x aligned=%d err=%d"
        % (int(dut.ack_rdata.value), int(dut.ack_aligned.value), int(dut.ack_err.value)))
    r.assert_(i, False)
    await ClockCycles(dut.clk, 4)
    s.rdata = 0x00000200
    r.assert_(i)
    assert await await_ack(dut, i)
    assert int(dut.ack_aligned.value) == 0, "0x200 & 0x5 != 0x5"
    assert int(dut.ack_err.value) == 0, "an unaligned link is not a bus error"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_bad_magic_is_an_error_not_an_unaligned_link(dut):
    r, s = await start(dut)
    i = RR_START if RR_START < N_REQ else 0
    r.setup(i, addr=0x7000, mask=0x5)
    s.rdata = BAD_MAGIC
    r.assert_(i)
    assert await await_ack(dut, i)
    assert int(dut.ack_err.value) == 1, "the bad-magic word must be reported as an error"
    assert int(dut.ack_aligned.value) == 0, "and never as aligned"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_slverr_is_an_error_and_never_aligned(dut):
    r, s = await start(dut)
    i = RR_START if RR_START < N_REQ else 0
    r.setup(i, addr=0x8000, mask=0x5)
    s.rdata = 0x00000005
    s.rresp = 2
    r.assert_(i)
    assert await await_ack(dut, i)
    assert int(dut.ack_err.value) == 1 and int(dut.ack_aligned.value) == 0, (
        "a non-OKAY response must be an error, and a masked match on error data is not a verdict")

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_write_completes_on_bresp_and_has_no_verdict(dut):
    r, s = await start(dut)
    i = 0
    r.setup(i, addr=0x9000, wdata=0xA5A5_1234, write=1)
    r.assert_(i)
    assert await await_ack(dut, i), "the write was never acked"
    print("NIA_DIAG write-test: aligned=%d err=%d writes=%s"
          % (int(dut.ack_aligned.value), int(dut.ack_err.value), s.writes[-2:]), flush=True)
    assert int(dut.ack_aligned.value) == 0, (
        "a write has no alignment verdict - got aligned=%d" % int(dut.ack_aligned.value))
    assert int(dut.ack_err.value) == 0
    assert s.writes and s.writes[-1] == (0x9000, 0xA5A5_1234), f"wrote {s.writes[-1:]}"

@cocotb.test(timeout_time=TIMEOUT_US, timeout_unit="us")
async def test_a_bus_that_never_answers_times_out_and_releases(dut):
    if TMO_CYC == 0:
        return
    r, s = await start(dut)
    i = RR_START if RR_START < N_REQ else 0
    j = 0 if RR_START >= 1 else (i + 1) % N_REQ
    r.setup(i, addr=0xA000, mask=0x5)
    r.setup(j, addr=0xB000, mask=0x5)
    s.answer = False
    r.assert_(i)
    assert await await_ack(dut, i, limit=8 * TMO_CYC), (
        "the executor never gave up on a bus that does not answer - that is the wedge, in our own RTL")
    assert int(dut.ack_err.value) == 1, "a timeout must be reported as an error"
    assert int(dut.tmo_count.value) >= 1, "the timeout must be counted, or it cannot be diagnosed"
    r.assert_(i, False)
    s.answer = True
    r.assert_(j)
    assert await await_ack(dut, j), (
        "a second requester was starved by one unanswered transaction - the bus was not released")
