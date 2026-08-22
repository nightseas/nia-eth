# ---------------------------------------------------------------------------
# File        : test_dcmac_drp_bridge.py
# Description : The bridge tests: identity and version round trip, a coherent halfword
#               pair, a high half read that issues no bus transaction, and a write to
#               either half that reaches the port without disturbing the other.
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

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

CLK_NS = 4
DRP_TIMEOUT = int(os.environ.get("DRP_TIMEOUT_CYC", "64"))

A_ID, A_VERSION, A_SCRATCH, A_CAPS = 0x00, 0x04, 0x08, 0x0C
A_STATUS, A_STICKY = 0x10, 0x1C
A_STSEEN, A_LINKEV, A_CTL, A_SEQ = 0x20, 0x24, 0x28, 0x2C
A_RXPHY, A_STATIDX, A_STATDATA, A_ROUNDS = 0x30, 0x34, 0x38, 0x3C

BRIDGE_STS_WORD = 0x3F
SENT_OOR = 0xBAD0
SENT_TIMEOUT = 0xBAD1

def drp_a(byte_off, half):
    return ((byte_off >> 2) << 1) | (1 if half else 0)

class DrpMaster:

    def __init__(self, dut, limit=4000):
        self.dut = dut
        self.limit = limit
        self.timeouts = 0

    async def _xact(self, addr, we, di=0):
        d = self.dut
        d.drp_addr.value = addr
        d.drp_di.value = di
        d.drp_we.value = 1 if we else 0
        d.drp_en.value = 1
        await RisingEdge(d.clk)
        d.drp_en.value = 0
        d.drp_we.value = 0
        for _ in range(self.limit):
            await RisingEdge(d.clk)
            if int(d.drp_rdy.value):
                return int(d.drp_do.value)
        self.timeouts += 1
        raise AssertionError(
            f"  VIOLATED - THE BRIDGE NEVER ANSWERED a DRP access to 0x{addr:06x} "
            f"(we={int(bool(we))}) within {self.limit} cycles. `rb_drp` has NO timeout: on real "
            f"hardware this leaves the register block's busy bit set FOREVER and the host polls a "
            f"bit that will never clear. That is the dead-MMIO signature, not a slow read.")

    async def rd(self, byte_off, half):
        return await self._xact(drp_a(byte_off, half), False)

    async def wr(self, byte_off, half, di):
        return await self._xact(drp_a(byte_off, half), True, di)

    async def rd32(self, byte_off):
        lo = await self.rd(byte_off, 0)
        hi = await self.rd(byte_off, 1)
        return (hi << 16) | lo

    async def rd_raw(self, addr):
        return await self._xact(addr, False)

async def _start(dut, seed=1):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rstn.value = 0
    dut.drp_en.value = 0
    dut.drp_we.value = 0
    dut.drp_addr.value = 0
    dut.drp_di.value = 0
    for s in ("link_up", "rx_status", "tx_status",
              "ctl_link_fault", "ctl_access_fault", "ctl_seq_busy"):
        if hasattr(dut, s):
            getattr(dut, s).value = 0
    for s, v in (("mac_fsm_state", 0),
                 ("ctl_rx_phy_status", 0), ("ctl_retry_cnt", 0), ("ctl_seq_state", 0),
                 ("ctl_seq_pc", 0), ("ctl_stat_rd_data", 0)):
        if hasattr(dut, s):
            getattr(dut, s).value = v
    if hasattr(dut, "axi_stall"):
        dut.axi_stall.value = 0
    if hasattr(dut, "axi_stall_data"):
        dut.axi_stall_data.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 8)
    return DrpMaster(dut)

async def _assert_idle(dut, name, cyc=64):
    for _ in range(cyc):
        await RisingEdge(dut.clk)
        if int(dut.drp_rdy.value):
            raise AssertionError(
                f"{name}: `drp_rdy` asserted while the bridge should be idle - a spurious ready is "
                f"as bad as none: `rb_drp` will latch garbage as the answer to the NEXT access.")
    assert not int(dut.busy.value), f"{name}: the bridge is still busy long after its transaction"

@cocotb.test()
async def test_ns36_read_id_and_version_round_trip(dut):
    m = await _start(dut)
    vid = await m.rd32(A_ID)
    ver = await m.rd32(A_VERSION)
    assert vid != 0 and vid != 0xFFFFFFFF, (
        f": ID read back 0x{vid:08x}. 0 means the AXI read never reached the CSR; all-ones "
        f"means nothing drove the bus - both are the 'window with no master' state  describes.")
    assert (ver >> 16) >= 1 and (ver & 0xFFFF) == 0, (
        f": VERSION 0x{ver:08x} is not a major.minor layout with minor 0 - the round trip "
        f"through the bridge is what this asserts, not the number")
    await _assert_idle(dut, "ns36")
    cocotb.log.info(": ID=0x%08x VERSION=0x%08x through the DRP window", vid, ver)

@cocotb.test()
async def test_ns38_halfword_pair_is_coherent(dut):
    m = await _start(dut)
    dut.ctl_rx_phy_status.value = 0x1234_5678
    await ClockCycles(dut.clk, 200)

    lo = await m.rd(A_RXPHY, 0)
    dut.ctl_rx_phy_status.value = 0xDEAD_BEEF
    await ClockCycles(dut.clk, 200)
    hi = await m.rd(A_RXPHY, 1)

    got = (hi << 16) | lo
    assert got == 0x1234_5678, (
        f"  VIOLATED - TORN READ: got 0x{got:08x}, expected 0x12345678. The high half was "
        f"fetched fresh instead of coming from the shadow latched at the half-0 access, so the two "
        f"halves are from different instants and the value never existed.")
    await _assert_idle(dut, "ns38_coherent")
    cocotb.log.info(": pair coherent across a mid-read change")

@cocotb.test()
async def test_ns38_high_half_issues_no_axi(dut):
    m = await _start(dut)
    await m.rd(A_STATDATA, 0)
    n0 = int(dut.dbg_axi_rd_count.value)
    await m.rd(A_STATDATA, 1)
    n1 = int(dut.dbg_axi_rd_count.value)
    assert n1 == n0, (
        f": the half-1 read issued {n1 - n0} AXI read(s). It must be served from the shadow: "
        f"a second bus access is both the tearing bug and twice the latency.")
    await _assert_idle(dut, "ns38_no_axi")

@cocotb.test()
async def test_ns38_write_low_half_reaches_ctl(dut):
    m = await _start(dut)
    await m.wr(A_CTL, 0, 0x0001)
    await ClockCycles(dut.clk, 300)
    saw = int(dut.ctl_bringup_restart_req.value) or int(dut.dbg_ctl_req_seen.value)
    assert saw, (
        "/: a DRP write of CTL[0] never produced `ctl_bringup_restart_req`. The window's "
        "request half is the reason 's monitor has a manual override at all.")
    await _assert_idle(dut, "ns38_write")

@cocotb.test()
async def test_ns38_write_high_half_preserves_low(dut):
    m = await _start(dut)
    await m.wr(A_SCRATCH, 0, 0xA5A5)
    await m.wr(A_SCRATCH, 1, 0x1234)
    got = await m.rd32(A_SCRATCH)
    assert got == 0x1234_A5A5, (
        f": SCRATCH reads 0x{got:08x}, expected 0x1234A5A5. If the low half is zero the "
        f"high-half write clobbered it, which means WSTRB is not being driven per half.")
    await _assert_idle(dut, "ns38_wstrb")

@cocotb.test()
async def test_drp16w_the_word_bound_is_enforced_and_moves(dut):
    n_word = int(dut.N_WORD.value)
    m = await _start(dut)

    n0 = int(dut.dbg_axi_rd_count.value)
    got = await m.rd_raw(n_word << 1)
    n1 = int(dut.dbg_axi_rd_count.value)
    assert got == SENT_OOR, (
        f": word {n_word} is the first above the map and returned 0x{got:04x}, "
        f"expected the OOR sentinel 0x{SENT_OOR:04x}")
    assert n1 == n0, f": word {n_word} is out of range and still issued an AXI read"

    n2 = int(dut.dbg_axi_rd_count.value)
    await m.rd_raw((n_word - 1) << 1)
    n3 = int(dut.dbg_axi_rd_count.value)
    assert n3 > n2, (
        f": word {n_word - 1} is the last word INSIDE the map and was not forwarded. "
        f"The bound is too small - this is the defect, in the direction that hides a real register")
    await _assert_idle(dut, "drp16w_bound")

@cocotb.test()
async def test_drp16w_word_16_is_the_link_wdt_and_needs_n_word_above_16(dut):
    n_word = int(dut.N_WORD.value)
    m = await _start(dut)
    w_wdt0 = 0x040 >> 2
    n0 = int(dut.dbg_axi_rd_count.value)
    got = await m.rd_raw(w_wdt0 << 1)
    n1 = int(dut.dbg_axi_rd_count.value)
    if n_word > w_wdt0:
        assert n1 > n0, (
            f" UNREACHABLE: N_WORD={n_word} is above 16 and LINK_WDT0 (CSR 0x040) was still "
            f"not forwarded")
        assert got != SENT_OOR, f": LINK_WDT0 answered the OOR sentinel at N_WORD={n_word}"
    else:
        assert got == SENT_OOR and n1 == n0, (
            f"at N_WORD={n_word} word 16 must be refused - this is the  silicon "
            f"behaviour, kept as the negative control")
    await _assert_idle(dut, "drp16w_wdt")

@cocotb.test()
async def test_ns37_out_of_range_answers_and_no_axi(dut):
    m = await _start(dut)
    n0 = int(dut.dbg_axi_rd_count.value)
    got = await m.rd_raw(1 << 12)
    n1 = int(dut.dbg_axi_rd_count.value)
    assert got == SENT_OOR, f": out-of-range read returned 0x{got:04x}, expected 0x{SENT_OOR:04x}"
    assert n1 == n0, ": an out-of-range access issued an AXI read anyway"
    await _assert_idle(dut, "ns37_oor")

@cocotb.test()
async def test_ns37_dead_axi_slave_still_answers(dut):
    m = await _start(dut)
    dut.axi_stall.value = 1
    got_r = await m.rd(A_STATUS, 0)
    assert got_r == SENT_TIMEOUT, (
        f": a read against a dead slave returned 0x{got_r:04x}, expected the timeout sentinel "
        f"0x{SENT_TIMEOUT:04x}")
    got_w = await m.wr(A_SCRATCH, 0, 0x1234)
    assert got_w == SENT_TIMEOUT, (
        f": a write against a dead slave returned 0x{got_w:04x}, expected 0x{SENT_TIMEOUT:04x}")
    dut.axi_stall.value = 0
    await ClockCycles(dut.clk, 32)
    vid = await m.rd32(A_ID)
    assert vid not in (0, 0xFFFFFFFF), (
        f": after the stall cleared, ID reads 0x{vid:08x} - the bridge did not recover, so the "
        f"timeout path leaves it in a state the host cannot get out of.")
    await _assert_idle(dut, "ns37_dead")
    cocotb.log.info(": bounded on a dead slave, both directions, and recovered")

@cocotb.test()
async def test_ns37_data_phase_stall_still_answers(dut):
    m = await _start(dut)
    dut.axi_stall_data.value = 1
    got_r = await m.rd(A_STATUS, 0)
    assert got_r == SENT_TIMEOUT, (
        f"  VIOLATED on the READ DATA phase: the slave accepted AR and never returned R, and "
        f"the bridge answered 0x{got_r:04x} instead of the timeout sentinel 0x{SENT_TIMEOUT:04x}.")
    got_w = await m.wr(A_SCRATCH, 0, 0x4321)
    assert got_w == SENT_TIMEOUT, (
        f"  VIOLATED on the WRITE RESPONSE phase: AW/W were accepted, B never came, and the "
        f"bridge answered 0x{got_w:04x} instead of 0x{SENT_TIMEOUT:04x}.")
    dut.axi_stall_data.value = 0
    await ClockCycles(dut.clk, 64)
    vid = await m.rd32(A_ID)
    assert vid not in (0, 0xFFFFFFFF), (
        f": after the data-phase stall cleared, ID reads 0x{vid:08x} - the bridge did not "
        f"recover.  This is the harder recovery of the two: an abandoned data phase leaves the SLAVE "
        f"holding a response the bridge has stopped waiting for.")
    await _assert_idle(dut, "ns37_data_phase")
    cocotb.log.info(": bounded on both DATA phases, and recovered")

@cocotb.test()
async def test_ns39_bridge_status_records_the_timeout(dut):
    m = await _start(dut)
    sts0 = await m.rd_raw((BRIDGE_STS_WORD << 1) | 0)
    assert sts0 == 0, f": the bridge status starts at 0x{sts0:04x}, expected 0"

    dut.axi_stall.value = 1
    await m.rd(A_STATUS, 0)
    dut.axi_stall.value = 0
    await ClockCycles(dut.clk, 32)
    dut.axi_stall_data.value = 1
    await m.rd(A_STATUS, 0)
    dut.axi_stall_data.value = 0
    await ClockCycles(dut.clk, 32)

    n0 = int(dut.dbg_axi_rd_count.value)
    sts1 = await m.rd_raw((BRIDGE_STS_WORD << 1) | 0)
    n1 = int(dut.dbg_axi_rd_count.value)
    assert sts1 & 0x1, (
        f": the bridge status reads 0x{sts1:04x} after two timeouts - bit 0 (sticky timeout) is "
        f"clear, so the failure is invisible and 's new channel is a second thing to distrust.")
    assert (sts1 >> 8) >= 2, (
        f": the timeout count is {sts1 >> 8} after timeouts on BOTH the address and the data "
        f"phase; expected >= 2. A count that misses a whole class of path is the B5 defect.")
    assert n1 == n0, ": reading the bridge's own status issued an AXI transaction"

    await m._xact((BRIDGE_STS_WORD << 1) | 0, True, 0x0001)
    sts2 = await m.rd_raw((BRIDGE_STS_WORD << 1) | 0)
    assert not (sts2 & 0x1), f": the sticky timeout did not clear (0x{sts2:04x})"
    await _assert_idle(dut, "ns39")
    cocotb.log.info(": timeouts recorded on both phases (0x%04x), cleared W1C", sts1)
