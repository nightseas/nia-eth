#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : test_dcmac_axis_pktgen.py
# Description : The loopback tests of the AXI-Stream instrument: identity, an unmapped
#               offset that answers rather than stalling, byte exactness at the minimum
#               frame and across beats, and frames that follow with no idle beat between
#               them.
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
from cocotb.triggers import ClockCycles, RisingEdge

DATA_W = int(os.environ.get("DATA_W", "512"))
KEEP_W = DATA_W // 8
LEN_MIN_HW = int(os.environ.get("LEN_MIN_HW", "64"))
LEN_MAX_HW = int(os.environ.get("LEN_MAX_HW", "9018"))

A_MODULE_TYPE = 0x00
A_MAP_VERSION = 0x04
A_BUS_CHECK = 0x08
A_AXIS_GEOMETRY = 0x0C
A_FEATURES = 0x10
A_CTL = 0x14
A_STATUS = 0x18
A_LEN_MIN = 0x1C
A_LEN_MAX = 0x20
A_LEN_MODE = 0x24
A_LEN_EFFECTIVE = 0x28
A_LEN_CLAMP_STICKY = 0x2C
A_TX_FRAME_LIMIT = 0x30
A_SNAPSHOT_ROUNDS = 0x34
A_TX_FRAMES = 0x40
A_TX_BYTES = 0x44
A_RX_FRAMES = 0x48
A_RX_BYTES = 0x4C
A_RX_ERR_FRAMES = 0x50
A_RX_MISMATCH_BEATS = 0x54
A_HDR_CTL = 0x80
A_UNMAPPED = 0x0FC

CTL_ENABLE = 0x1
CTL_CLEAR = 0x2
ST_BUSY = 0x01
ST_DONE = 0x02

NET_NS = 4.0
AXIL_NS = 4.0


async def wr(dut, addr, data):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1
    aw = w = False
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
    assert aw and w, f"write to 0x{addr:03x} never handshook"
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_bvalid.value):
            resp = int(dut.s_axil_bresp.value)
            dut.s_axil_bready.value = 0
            return resp
    raise AssertionError(f"write to 0x{addr:03x} never completed")


async def rd(dut, addr):
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value = 1
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_arready.value):
            dut.s_axil_arvalid.value = 0
            break
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_rvalid.value):
            v = int(dut.s_axil_rdata.value)
            resp = int(dut.s_axil_rresp.value)
            dut.s_axil_rready.value = 0
            return v, resp
    raise AssertionError(f"read from 0x{addr:03x} never returned")


async def start(dut, tready=1):
    cocotb.start_soon(Clock(dut.net_clk, NET_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.axil_aclk, AXIL_NS, units="ns").start())
    dut.net_rstn.value = 0
    dut.axil_aresetn.value = 0
    dut.tready_force.value = tready
    dut.link_up.value = 1
    for sig in ("s_axil_awaddr", "s_axil_awvalid", "s_axil_wdata", "s_axil_wstrb",
                "s_axil_wvalid", "s_axil_bready", "s_axil_araddr", "s_axil_arvalid",
                "s_axil_rready"):
        getattr(dut, sig).value = 0
    await ClockCycles(dut.axil_aclk, 8)
    dut.net_rstn.value = 1
    dut.axil_aresetn.value = 1
    await ClockCycles(dut.axil_aclk, 8)


async def run_burst(dut, length, frames, mode=0, hdr=0):
    await wr(dut, A_CTL, CTL_CLEAR)
    await wr(dut, A_CTL, 0)
    await wr(dut, A_LEN_MIN, length)
    await wr(dut, A_LEN_MAX, length)
    await wr(dut, A_LEN_MODE, mode)
    await wr(dut, A_HDR_CTL, hdr)
    await wr(dut, A_TX_FRAME_LIMIT, frames)
    await wr(dut, A_CTL, CTL_ENABLE)
    for _ in range(4000):
        st, _ = await rd(dut, A_STATUS)
        if st & ST_DONE:
            break
    else:
        raise AssertionError("the burst never reported done")
    await wr(dut, A_CTL, 0)
    await ClockCycles(dut.axil_aclk, 16)
    out = {}
    for name, addr in (("txf", A_TX_FRAMES), ("txb", A_TX_BYTES), ("rxf", A_RX_FRAMES),
                       ("rxb", A_RX_BYTES), ("err", A_RX_ERR_FRAMES),
                       ("mis", A_RX_MISMATCH_BEATS), ("len", A_LEN_EFFECTIVE),
                       ("clamp", A_LEN_CLAMP_STICKY), ("rounds", A_SNAPSHOT_ROUNDS)):
        out[name], _ = await rd(dut, addr)
    return out


@cocotb.test()
async def test_identity(dut):
    await start(dut)
    mt, r1 = await rd(dut, A_MODULE_TYPE)
    mv, r2 = await rd(dut, A_MAP_VERSION)
    geo, r3 = await rd(dut, A_AXIS_GEOMETRY)
    assert mt == 0x4E415047, f"MODULE_TYPE 0x{mt:08X}"
    assert mv == 0x00030001, f"MAP_VERSION 0x{mv:08X}"
    assert geo == ((KEEP_W << 16) | DATA_W), f"AXIS_GEOMETRY 0x{geo:08X}"
    assert (r1, r2, r3) == (0, 0, 0)
    await wr(dut, A_BUS_CHECK, 0xA5A51234)
    v, _ = await rd(dut, A_BUS_CHECK)
    assert v == 0xA5A51234, f"BUS_CHECK 0x{v:08X}"


@cocotb.test()
async def test_unmapped_offset_answers_and_does_not_stall(dut):
    await start(dut)
    v, resp = await rd(dut, A_UNMAPPED)
    assert resp == 2, f"an unmapped read answered with rresp {resp}, not SLVERR"
    assert v == 0
    resp = await wr(dut, A_UNMAPPED, 0xDEADBEEF)
    assert resp == 2, f"an unmapped write answered with bresp {resp}, not SLVERR"
    mt, _ = await rd(dut, A_MODULE_TYPE)
    assert mt == 0x4E415047, "the register path did not survive an unmapped access"


@cocotb.test()
async def test_byte_exact_min_frame(dut):
    await start(dut)
    c = await run_burst(dut, 64, 500)
    assert c["txf"] == 500, f"TX_FRAMES {c['txf']}"
    assert c["rxf"] == 500, f"RX_FRAMES {c['rxf']}"
    assert c["txb"] == 500 * 64, f"TX_BYTES {c['txb']}"
    assert c["rxb"] == 500 * 64, f"RX_BYTES {c['rxb']}"
    assert c["mis"] == 0, f"RX_MISMATCH_BEATS {c['mis']}"
    assert c["err"] == 0, f"RX_ERR_FRAMES {c['err']}"
    assert c["len"] == 64, f"LEN_EFFECTIVE {c['len']}"
    assert c["rounds"] != 0, "the snapshot never handshook"


@cocotb.test()
async def test_byte_exact_multi_beat(dut):
    await start(dut)
    lengths = [65, 128, 512, 1518]
    for extra in (4096, LEN_MAX_HW - 1, LEN_MAX_HW):
        if LEN_MIN_HW <= extra <= LEN_MAX_HW and extra not in lengths:
            lengths.append(extra)
    for length in lengths:
        c = await run_burst(dut, length, 40)
        assert c["txf"] == 40 and c["rxf"] == 40, f"len {length}: frames {c['txf']}/{c['rxf']}"
        assert c["txb"] == 40 * length, f"len {length}: TX_BYTES {c['txb']}"
        assert c["rxb"] == 40 * length, f"len {length}: RX_BYTES {c['rxb']}"
        assert c["mis"] == 0, f"len {length}: mismatch {c['mis']}"
        assert c["err"] == 0, f"len {length}: RX_ERR_FRAMES {c['err']}"
        assert c["len"] == length, f"len {length}: LEN_EFFECTIVE {c['len']}"


@cocotb.test()
async def test_frames_follow_with_no_idle_beat(dut):
    """The rate claim of study 15.11 requirement 4 is one frame per beat, and a generator that
    inserts one idle cycle between frames delivers half of it. At 64 bytes a frame is one beat, so
    the burst must occupy exactly as many cycles as it has frames."""
    await start(dut)
    await wr(dut, A_CTL, CTL_CLEAR)
    await wr(dut, A_CTL, 0)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 64)
    await wr(dut, A_LEN_MODE, 0)
    await wr(dut, A_TX_FRAME_LIMIT, 200)

    async def watch():
        beats = 0
        gaps = 0
        seen = False
        idle_after = 0
        while True:
            await RisingEdge(dut.net_clk)
            v = int(dut.tx_tvalid.value) and int(dut.tx_tready.value)
            if v:
                beats += 1
                seen = True
                idle_after = 0
            elif seen:
                idle_after += 1
                if idle_after > 8:
                    break
                gaps += 1
            if beats >= 200 and idle_after > 8:
                break
        return beats, gaps

    task = cocotb.start_soon(watch())
    await wr(dut, A_CTL, CTL_ENABLE)
    beats, gaps = await task
    await wr(dut, A_CTL, 0)
    assert beats == 200, f"{beats} accepted beats for 200 single-beat frames"
    assert gaps <= 8, f"{gaps} idle cycles inside a 200 frame burst, so frames do not follow one another"


@cocotb.test()
async def test_minimum_frame_is_clamped(dut):
    """PG369 p119 and p126: the minimum frame is four segments even when aborting, and nothing in the
    DCMAC pads, so a shorter length must be clamped in hardware and reported as clamped."""
    await start(dut)
    c = await run_burst(dut, 48, 20)
    assert c["len"] == 64, f"a 48 byte request produced LEN_EFFECTIVE {c['len']}"
    assert c["clamp"] == 1, "the clamp is not sticky"
    assert c["txb"] == 20 * 64, f"TX_BYTES {c['txb']}"
    assert c["mis"] == 0, f"mismatch {c['mis']}"


@cocotb.test()
async def test_maximum_frame_is_clamped(dut):
    """The counterpart of test_minimum_frame_is_clamped. LEN_MAX_HW is what the instrument was
    built for, and a longer request must be clamped to it in hardware and reported as clamped
    rather than truncated on the wire or wrapped in a counter."""
    await start(dut)
    c = await run_burst(dut, LEN_MAX_HW + 1000, 20)
    assert c["len"] == LEN_MAX_HW, \
        f"a {LEN_MAX_HW + 1000} byte request produced LEN_EFFECTIVE {c['len']}"
    assert c["clamp"] == 1, "the clamp is not sticky"
    assert c["txf"] == 20 and c["rxf"] == 20, f"frames {c['txf']}/{c['rxf']}"
    assert c["txb"] == 20 * LEN_MAX_HW, f"TX_BYTES {c['txb']}"
    assert c["rxb"] == 20 * LEN_MAX_HW, f"RX_BYTES {c['rxb']}"
    assert c["mis"] == 0, f"mismatch {c['mis']}"
    assert c["err"] == 0, f"RX_ERR_FRAMES {c['err']}"


@cocotb.test()
async def test_header_mode_is_byte_exact(dut):
    await start(dut)
    await wr(dut, A_CTL, CTL_CLEAR)
    await wr(dut, A_CTL, 0)
    for addr, val in ((0x84, 0x11223344), (0x88, 0x0000AABB), (0x8C, 0x55667788),
                      (0x90, 0x0000CCDD), (0x94, 0x00000800)):
        await wr(dut, addr, val)
    c = await run_burst(dut, 128, 30, hdr=1)
    assert c["txf"] == 30 and c["rxf"] == 30, f"frames {c['txf']}/{c['rxf']}"
    assert c["txb"] == 30 * 128 and c["rxb"] == 30 * 128, f"bytes {c['txb']}/{c['rxb']}"
    assert c["mis"] == 0, f"mismatch {c['mis']} with the header enabled"


@cocotb.test()
async def test_random_length_is_byte_exact(dut):
    await start(dut)
    await wr(dut, A_CTL, CTL_CLEAR)
    await wr(dut, A_CTL, 0)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 512)
    await wr(dut, A_LEN_MODE, 1)
    await wr(dut, A_TX_FRAME_LIMIT, 60)
    await wr(dut, A_CTL, CTL_ENABLE)
    for _ in range(4000):
        st, _ = await rd(dut, A_STATUS)
        if st & ST_DONE:
            break
    else:
        raise AssertionError("the random burst never reported done")
    await wr(dut, A_CTL, 0)
    await ClockCycles(dut.axil_aclk, 16)
    txf, _ = await rd(dut, A_TX_FRAMES)
    rxf, _ = await rd(dut, A_RX_FRAMES)
    txb, _ = await rd(dut, A_TX_BYTES)
    rxb, _ = await rd(dut, A_RX_BYTES)
    mis, _ = await rd(dut, A_RX_MISMATCH_BEATS)
    assert txf == 60 and rxf == 60, f"frames {txf}/{rxf}"
    assert txb == rxb, f"bytes {txb} against {rxb}"
    assert 60 * 64 <= txb <= 60 * 512, f"TX_BYTES {txb} is outside the requested range"
    assert mis == 0, f"mismatch {mis} in random length mode"
