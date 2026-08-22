# ---------------------------------------------------------------------------
# File        : test_dcmac_link_csr_wdt.py
# Description : The watchdog period register tests: the default is the parameter, a legal
#               value is in force, zero means the parameter, and a value above or below
#               the limits is clamped and reported.
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

N_GROUP = int(os.environ.get("N_GROUP", "1"))
LINK_WDT_MS = int(os.environ.get("LINK_WDT_MS", "40"))
LINK_WDT_MS_MIN = int(os.environ.get("LINK_WDT_MS_MIN", "10"))
LINK_WDT_MS_MAX = int(os.environ.get("LINK_WDT_MS_MAX", "60000"))

A_VERSION = 0x004
A_CTL = 0x028
A_WDT0 = 0x040

VERSION_EXPECT = 0x0003_0000

CLK_NS = 8
SEG_NS = 3
TX_NS = 4
RX_NS = 4

def _wdt_addr(g):
    return A_WDT0 + 4 * g

def _expect_eff(req):
    if req == 0:
        return LINK_WDT_MS
    if req < LINK_WDT_MS_MIN:
        return LINK_WDT_MS_MIN
    if req > LINK_WDT_MS_MAX:
        return LINK_WDT_MS_MAX
    return req

def _expect_oor(req):
    return req != 0 and (req < LINK_WDT_MS_MIN or req > LINK_WDT_MS_MAX)

async def _start(dut):
    cocotb.start_soon(Clock(dut.axil_aclk, CLK_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.seg_clk, SEG_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.tx_clk, TX_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.rx_clk, RX_NS, units="ns").start())

    dut.axil_aresetn.value = 0
    dut.seg_rstn.value = 0
    dut.tx_rstn.value = 0
    dut.rx_rstn.value = 0
    for sig, val in (("s_axil_awaddr", 0), ("s_axil_awvalid", 0), ("s_axil_wdata", 0),
                     ("s_axil_wstrb", 0), ("s_axil_wvalid", 0), ("s_axil_bready", 0),
                     ("s_axil_araddr", 0), ("s_axil_arvalid", 0), ("s_axil_rready", 0),
                     ("link_up", 0), ("mac_fsm_state", 0),
                     ("rx_status", 0), ("tx_status", 0), ("ctl_link_fault", 0),
                     ("ctl_access_fault", 0), ("ctl_seq_busy", 0), ("ctl_rx_phy_status", 0),
                     ("ctl_retry_cnt", 0), ("ctl_seq_state", 0), ("ctl_seq_pc", 0),
                     ("ctl_stat_rd_data", 0)):
        getattr(dut, sig).value = val
    await ClockCycles(dut.axil_aclk, 8)
    dut.axil_aresetn.value = 1
    dut.seg_rstn.value = 1
    dut.tx_rstn.value = 1
    dut.rx_rstn.value = 1
    await ClockCycles(dut.axil_aclk, 8)

async def _wr(dut, addr, data, strb=0xF):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = strb
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1
    aw, w = False, False
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if not aw and int(dut.s_axil_awready.value):
            aw = True
            dut.s_axil_awvalid.value = 0
        if not w and int(dut.s_axil_wready.value):
            w = True
            dut.s_axil_wvalid.value = 0
        if aw and w:
            break
    assert aw and w, "the write handshake never completed"
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_bvalid.value):
            break
    await RisingEdge(dut.axil_aclk)
    dut.s_axil_bready.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value = 0

async def _rd(dut, addr):
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value = 1
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_arready.value):
            break
    dut.s_axil_arvalid.value = 0
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_rvalid.value):
            val = int(dut.s_axil_rdata.value)
            await RisingEdge(dut.axil_aclk)
            dut.s_axil_rready.value = 0
            return val
    raise AssertionError("the read never returned")

def _decode(word):
    return {
        "eff": word & 0xFFFF,
        "ngroup": (word >> 16) & 0xF,
        "rsvd": (word >> 20) & 0x3FF,
        "sticky": (word >> 30) & 1,
        "now": (word >> 31) & 1,
    }

@cocotb.test()
async def test_ns59_default_is_the_parameter(dut):
    await _start(dut)
    for g in range(N_GROUP):
        f = _decode(await _rd(dut, _wdt_addr(g)))
        assert f["eff"] == LINK_WDT_MS, \
            f": group {g} window reads {f['eff']}, expected the parameter {LINK_WDT_MS}"
        assert f["ngroup"] == N_GROUP, \
            f": the N_GROUP field reads {f['ngroup']}, expected {N_GROUP}"
        assert f["rsvd"] == 0, ": reserved bits must read 0"
        assert f["sticky"] == 0 and f["now"] == 0, \
            ": no clamp has happened, so neither indication may be set"
        dut._log.info("NIA_NS59 g=%d default_eff=%d ngroup=%d", g, f["eff"], f["ngroup"])

@cocotb.test()
async def test_ns59_a_legal_value_is_in_force(dut):
    await _start(dut)
    val = max(LINK_WDT_MS_MIN, min(LINK_WDT_MS_MAX, 123))
    await _wr(dut, _wdt_addr(0), val)
    f = _decode(await _rd(dut, _wdt_addr(0)))
    assert f["eff"] == val, f": wrote {val}, the window reads {f['eff']}"
    assert f["now"] == 0 and f["sticky"] == 0, \
        ": a legal value must raise no clamp indication"

@cocotb.test()
async def test_ns59_zero_means_the_parameter(dut):
    await _start(dut)
    await _wr(dut, _wdt_addr(0), max(LINK_WDT_MS_MIN, 99))
    await _wr(dut, _wdt_addr(0), 0)
    f = _decode(await _rd(dut, _wdt_addr(0)))
    assert f["eff"] == LINK_WDT_MS, \
        f": a written 0 gave {f['eff']}, expected the parameter {LINK_WDT_MS}"
    assert f["eff"] != 0, ": the effective window may never be 0"
    assert f["now"] == 0 and f["sticky"] == 0, \
        ": 0 is a legal request, so it is not an out-of-range event"

@cocotb.test()
async def test_ns59_above_max_is_clamped_and_reported(dut):
    await _start(dut)
    req = 0xFFFE if LINK_WDT_MS_MAX < 0xFFFE else 0xFFFF
    if req <= LINK_WDT_MS_MAX:
        dut._log.info("NIA_NS59 skip_above_max LINK_WDT_MS_MAX=%d leaves no room", LINK_WDT_MS_MAX)
        return
    await _wr(dut, _wdt_addr(0), req)
    f = _decode(await _rd(dut, _wdt_addr(0)))
    assert f["eff"] == _expect_eff(req) == LINK_WDT_MS_MAX, \
        f": {req} was not clamped to {LINK_WDT_MS_MAX}; the window reads {f['eff']}"
    assert f["now"] == 1, ": the live clamp indication must be set while the request is illegal"
    assert f["sticky"] == 1, ": the clamp must latch sticky"
    dut._log.info("NIA_NS59 above_max req=%d eff=%d now=%d sticky=%d",
                  req, f["eff"], f["now"], f["sticky"])

@cocotb.test()
async def test_ns59_below_min_is_clamped_and_reported(dut):
    await _start(dut)
    if LINK_WDT_MS_MIN <= 1:
        dut._log.info("NIA_NS59 skip_below_min LINK_WDT_MS_MIN=%d leaves no room", LINK_WDT_MS_MIN)
        return
    await _wr(dut, _wdt_addr(0), 1)
    f = _decode(await _rd(dut, _wdt_addr(0)))
    assert f["eff"] == LINK_WDT_MS_MIN, \
        f": 1 was not raised to {LINK_WDT_MS_MIN}; the window reads {f['eff']}"
    assert f["now"] == 1 and f["sticky"] == 1, \
        ": a clamp at the lower end must set both indications too"

@cocotb.test()
async def test_ns59_sticky_is_w1c_and_leaves_the_window(dut):
    await _start(dut)
    legal = max(LINK_WDT_MS_MIN, min(LINK_WDT_MS_MAX, 250))
    await _wr(dut, _wdt_addr(0), legal)

    if LINK_WDT_MS_MIN > 1:
        await _wr(dut, _wdt_addr(0), 1)
        f = _decode(await _rd(dut, _wdt_addr(0)))
        assert f["sticky"] == 1, ": the clamp did not latch, so this test cannot run"
        await _wr(dut, _wdt_addr(0), legal)
        f = _decode(await _rd(dut, _wdt_addr(0)))
        assert f["eff"] == legal, ": the legal value did not take"
        assert f["now"] == 0, ": the live indication must follow the stored request"
        assert f["sticky"] == 1, ": the sticky indication must survive a later legal write"

        await _wr(dut, _wdt_addr(0), 1 << 30)
        f = _decode(await _rd(dut, _wdt_addr(0)))
        assert f["sticky"] == 0, ": the W1C did not clear the sticky indication"
        assert f["eff"] == legal, \
            f" VIOLATED: the W1C moved the window from {legal} to {f['eff']}"

    await _wr(dut, _wdt_addr(0), 0xFFFF_FFFF)
    f = _decode(await _rd(dut, _wdt_addr(0)))
    assert f["eff"] == legal, \
        f" VIOLATED: an all-ones write moved the window from {legal} to {f['eff']}"
    assert f["ngroup"] == N_GROUP, ": the N_GROUP field is read-only"

@cocotb.test()
async def test_ns59_the_value_reaches_the_tx_domain(dut):
    await _start(dut)
    val = max(LINK_WDT_MS_MIN, min(LINK_WDT_MS_MAX, 321))
    await _wr(dut, _wdt_addr(0), val)
    await ClockCycles(dut.tx_clk, 64)
    got = int(dut.link_wdt_ms.value) & 0xFFFF
    assert got == val, f": link_wdt_ms[0] in tx_clk reads {got}, expected {val}"

    if LINK_WDT_MS_MIN > 1:
        await _wr(dut, _wdt_addr(0), 1)
        await ClockCycles(dut.tx_clk, 64)
        got = int(dut.link_wdt_ms.value) & 0xFFFF
        assert got == LINK_WDT_MS_MIN, \
            f" VIOLATED: an unclamped {got} crossed into tx_clk"
        dut._log.info("NIA_NS59 tx_domain clamped=%d", got)

@cocotb.test()
async def test_ns59_groups_are_independent(dut):
    await _start(dut)
    if N_GROUP < 2:
        dut._log.info("NIA_NS59 skip_groups N_GROUP=%d - run the dual variant for this", N_GROUP)
        return
    a = max(LINK_WDT_MS_MIN, min(LINK_WDT_MS_MAX, 111))
    b = max(LINK_WDT_MS_MIN, min(LINK_WDT_MS_MAX, 222))
    await _wr(dut, _wdt_addr(0), a)
    await _wr(dut, _wdt_addr(1), b)
    fa = _decode(await _rd(dut, _wdt_addr(0)))
    fb = _decode(await _rd(dut, _wdt_addr(1)))
    assert fa["eff"] == a and fb["eff"] == b, \
        f" VIOLATED: the groups are not independent (read {fa['eff']} and {fb['eff']})"
    await ClockCycles(dut.tx_clk, 64)
    flat = int(dut.link_wdt_ms.value)
    assert (flat & 0xFFFF) == a and ((flat >> 16) & 0xFFFF) == b, \
        f" VIOLATED: the tx-domain vector is 0x{flat:08x}, expected {b} over {a}"

    if LINK_WDT_MS_MIN > 1:
        await _wr(dut, _wdt_addr(1), 1)
        fa = _decode(await _rd(dut, _wdt_addr(0)))
        fb = _decode(await _rd(dut, _wdt_addr(1)))
        assert fb["sticky"] == 1, ": group 1's clamp did not latch"
        assert fa["sticky"] == 0, \
            " VIOLATED: group 1's clamp set group 0's sticky indication"
        assert fa["eff"] == a, " VIOLATED: group 1's write moved group 0's window"

@cocotb.test()
async def test_ns59_version_reports_the_new_layout(dut):
    await _start(dut)
    got = await _rd(dut, A_VERSION)
    assert got == VERSION_EXPECT, \
        f": VERSION reads 0x{got:08x}, expected 0x{VERSION_EXPECT:08x}"

@cocotb.test()
async def test_ns59_ctl_bits_are_undisturbed(dut):
    await _start(dut)
    await _wr(dut, A_CTL, 0x2)
    await ClockCycles(dut.tx_clk, 64)
    assert int(dut.ctl_stats_req.value) == 1, \
        "the widened push handshake broke CTL[1] -> ctl_stats_req"
    assert int(dut.ctl_bringup_restart_req.value) == 0, "CTL[0] must not follow CTL[1]"
    assert int(dut.ctl_rx_datapath_reset_req.value) == 0, "CTL[3] must stay 0"
    assert int(dut.ctl_tx_datapath_reset_req.value) == 0, "CTL[4] must stay 0"

    await _wr(dut, 0x034, 7)
    await ClockCycles(dut.tx_clk, 64)
    assert int(dut.ctl_stat_rd_idx.value) == 7, \
        f"the append shifted STATIDX: ctl_stat_rd_idx reads {int(dut.ctl_stat_rd_idx.value)}"
    dut._log.info("NIA_NS59 ctl_undisturbed stats_req=1 stat_rd_idx=7")
