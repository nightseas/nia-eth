# ---------------------------------------------------------------------------
# File        : test_dcmac_seg_pktgen.py
# Description : The tests of the segmented instrument: identity and defaults, a length
#               outside the range clamped and reported, a fixed and a random length stream
#               that is a contiguous counter, and a segment layout that obeys the client
#               rules.
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

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
SEG_B = SEG_W // 8
LEN_MIN_HW = int(os.environ.get("LEN_MIN_HW", "60"))
LEN_MAX_HW = int(os.environ.get("LEN_MAX_HW", "1518"))

AXIL_NS = 8
SEG_NS = 2.56

A_MODULE_TYPE = 0x00
A_MAP_VERSION = 0x04
A_BUS_CHECK = 0x08
A_SEG_GEOMETRY = 0x0C
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

CTL_ENABLE = 0x1
CTL_CLEAR = 0x2

LEN_MODE_FIXED = 0
LEN_MODE_RANDOM = 1

ST_BUSY = 0x1
ST_DONE = 0x2
ST_STALLED = 0x4
ST_UNDERFLOW = 0x8
ST_OVERFLOW = 0x10

MODULE_TYPE_EXPECT = 0x4E535047
MAP_VERSION_MAJOR = 3
FEATURE_HDR = 0x1

PRIME_BEATS = 4000


async def quiesce(dut):
    """Stop a run and let the transmit pipeline drain before anything else happens.

    Every test used to end by simply leaving its loop with CTL_ENABLE still set, which abandons the
    generator in the middle of a frame. At N_SEG=8 that costs one payload context discontinuity per
    abandoned run, and the derived chain's own contiguity assertion tolerates the first and stops the
    simulation on the second: dcmac_seg_pktgen_chain.sv:1974, bisected 2026-08-16. The design rule is
    the same one the hardware test follows, that a run ends on TX_FRAME_LIMIT or by clearing enable
    and draining, so the harness follows it too.
    """
    dut.tx_seg_ready.value = 1
    await wr(dut, A_CTL, 0)
    idle = 0
    for _ in range(4096):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value):
            idle = 0
        else:
            idle += 1
            if idle >= 64:
                return
    raise AssertionError("the transmit path did not go idle after CTL_ENABLE was cleared")


async def start(dut):
    cocotb.start_soon(Clock(dut.axil_aclk, AXIL_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.seg_clk, SEG_NS, units="ns").start())

    dut.axil_aresetn.value = 0
    dut.seg_rstn.value = 0
    dut.link_up.value = 1
    dut.ctl_tx_enable.value = 1
    dut.tx_rst_seg.value = 0
    dut.tx_seg_ready.value = 1
    dut.rx_seg_valid.value = 0
    dut.rx_seg_dat.value = 0
    dut.rx_seg_ena.value = 0
    dut.rx_seg_sop.value = 0
    dut.rx_seg_eop.value = 0
    dut.rx_seg_err.value = 0
    dut.rx_seg_mty.value = 0
    for sig in ("s_axil_awaddr", "s_axil_awvalid", "s_axil_wdata", "s_axil_wstrb",
                "s_axil_wvalid", "s_axil_bready", "s_axil_araddr", "s_axil_arvalid",
                "s_axil_rready"):
        getattr(dut, sig).value = 0
    await ClockCycles(dut.axil_aclk, 8)
    dut.axil_aresetn.value = 1
    dut.seg_rstn.value = 1
    await ClockCycles(dut.axil_aclk, 8)


async def wr(dut, addr, data):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1
    aw = False
    w = False
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
            dut.s_axil_bready.value = 0
            return
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
    else:
        raise AssertionError(f"read of 0x{addr:03x} never accepted")
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_rvalid.value):
            v = int(dut.s_axil_rdata.value)
            dut.s_axil_rready.value = 0
            return v
    raise AssertionError(f"read of 0x{addr:03x} never returned")


def seg_slice(word, s, width):
    return (word >> (s * width)) & ((1 << width) - 1)


def dump_history(dut, history, seg, frames_done):
    dut._log.error("NIA_SEG_PKTGEN violation at segment %d after %d frame(s)", seg, frames_done)
    for it, beat, ena, sop, eop, mty in history:
        dut._log.error("NIA_SEG_PKTGEN cycle=%d beat=%d ena=0x%x sop=0x%x eop=0x%x mty=0x%x",
                       it, beat, ena, sop, eop, mty)


async def collect(dut, cycles):
    frames = []
    cur = bytearray()
    started = False
    used_beats = 0
    history = []
    for it in range(cycles):
        await RisingEdge(dut.seg_clk)
        if not (int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value)):
            continue
        dat = int(dut.tx_seg_dat.value)
        ena = int(dut.tx_seg_ena.value)
        sop = int(dut.tx_seg_sop.value)
        eop = int(dut.tx_seg_eop.value)
        mty = int(dut.tx_seg_mty.value)
        if ena == 0:
            continue
        used_beats += 1
        history.append((it, used_beats, ena, sop, eop, mty))
        if len(history) > 4:
            history.pop(0)
        for s in range(N_SEG):
            if not (ena >> s) & 1:
                continue
            if (sop >> s) & 1:
                if cur:
                    dump_history(dut, history, s, len(frames))
                    raise AssertionError("a start of frame arrived while a frame was open")
                started = True
                cur = bytearray()
            if not started:
                dump_history(dut, history, s, len(frames))
                raise AssertionError("a segment carried data before any start of frame")
            n = SEG_B - (seg_slice(mty, s, 4) if (eop >> s) & 1 else 0)
            seg = seg_slice(dat, s, SEG_W)
            for b in range(n):
                cur.append((seg >> (b * 8)) & 0xFF)
            if (eop >> s) & 1:
                frames.append(bytes(cur))
                cur = bytearray()
                started = False
    return frames, used_beats


def assert_contiguous(frames, note):
    stream = b"".join(frames)
    if not stream:
        return 0
    first = stream[0]
    for i, v in enumerate(stream):
        want = (first + i) & 0xFF
        assert v == want, f"{note}: byte {i} of the stream is 0x{v:02x}, expected 0x{want:02x}"
    return len(stream)


@cocotb.test()
async def test_identity_and_defaults(dut):
    await start(dut)
    got = await rd(dut, A_MODULE_TYPE)
    assert got == MODULE_TYPE_EXPECT, \
        f"MODULE TYPE reads 0x{got:08x}, expected 0x{MODULE_TYPE_EXPECT:08x}"
    got = await rd(dut, A_MAP_VERSION)
    assert (got >> 16) == MAP_VERSION_MAJOR, \
        f"MAP VERSION major is {got >> 16}, expected {MAP_VERSION_MAJOR}"
    got = await rd(dut, A_FEATURES)
    assert got & FEATURE_HDR, f"FEATURES reads 0x{got:08x} and does not report the header overlay"
    got = await rd(dut, A_SEG_GEOMETRY)
    assert got == ((N_SEG << 16) | SEG_W), f"SEG_GEOMETRY reads 0x{got:08x}"
    got = await rd(dut, A_LEN_EFFECTIVE)
    assert (got & 0xFFFF) == LEN_MIN_HW, f"LEN_EFFECTIVE min reads {got & 0xFFFF}"
    assert (got >> 16) == LEN_MAX_HW, f"LEN_EFFECTIVE max reads {got >> 16}"
    await wr(dut, A_BUS_CHECK, 0xA5A55A5A)
    got = await rd(dut, A_BUS_CHECK)
    assert got == 0xA5A55A5A, f"BUS_CHECK reads 0x{got:08x}"


@cocotb.test()
async def test_out_of_range_length_is_clamped_and_reported(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 1)
    await wr(dut, A_LEN_MAX, 100000)
    got = await rd(dut, A_LEN_EFFECTIVE)
    assert (got & 0xFFFF) == LEN_MIN_HW, f"LEN_EFFECTIVE min reads {got & 0xFFFF}"
    assert (got >> 16) == LEN_MAX_HW, f"LEN_EFFECTIVE max reads {got >> 16}"
    sticky = await rd(dut, A_LEN_CLAMP_STICKY)
    assert sticky & 1, "the clamp did not report itself"
    await wr(dut, A_LEN_CLAMP_STICKY, 1)
    await wr(dut, A_LEN_MIN, LEN_MIN_HW)
    await wr(dut, A_LEN_MAX, LEN_MAX_HW)
    sticky = await rd(dut, A_LEN_CLAMP_STICKY)
    assert (sticky & 1) == 0, "the sticky clamp indication did not clear on write one"


@cocotb.test()
async def test_fixed_length_stream_is_a_contiguous_counter(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 64)
    await wr(dut, A_CTL, CTL_ENABLE)
    frames, _ = await collect(dut, PRIME_BEATS)
    assert len(frames) >= 8, f"only {len(frames)} frame(s) were produced"
    for f in frames:
        assert len(f) == 64, f"a frame is {len(f)} bytes, expected 64"
    n = assert_contiguous(frames, "fixed 64")
    status = await rd(dut, A_STATUS)
    assert not (status & ST_UNDERFLOW), "the client bus underflowed"
    assert not (status & ST_OVERFLOW), "the generator overflowed its buffer"
    dut._log.info("NIA_SEG_PKTGEN fixed 64 B frames=%d stream_bytes=%d contiguous", len(frames), n)
    await quiesce(dut)


@cocotb.test()
async def test_random_length_stays_in_range_and_contiguous(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 60)
    await wr(dut, A_LEN_MAX, 67)
    await wr(dut, A_LEN_MODE, LEN_MODE_RANDOM)
    await wr(dut, A_CTL, CTL_ENABLE)
    frames, _ = await collect(dut, PRIME_BEATS)
    assert len(frames) >= 10, f"only {len(frames)} frame(s) were produced"
    lens = [len(f) for f in frames]
    for v in lens:
        assert 60 <= v <= 67, f"a frame is {v} bytes, outside 60 to 67"
    assert_contiguous(frames, "random 60..67")
    dut._log.info("NIA_SEG_PKTGEN random 60..67 frames=%d lengths=%s", len(frames), lens[:12])
    await quiesce(dut)


@cocotb.test()
async def test_segment_layout_obeys_the_client_rules(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 60)
    await wr(dut, A_LEN_MAX, 1518)
    await wr(dut, A_LEN_MODE, LEN_MODE_RANDOM)
    await wr(dut, A_CTL, CTL_ENABLE)
    beats = 0
    for _ in range(PRIME_BEATS):
        await RisingEdge(dut.seg_clk)
        if not (int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value)):
            continue
        ena = int(dut.tx_seg_ena.value)
        eop = int(dut.tx_seg_eop.value)
        mty = int(dut.tx_seg_mty.value)
        if ena == 0:
            continue
        beats += 1
        for s in range(N_SEG):
            if s > 0 and ((ena >> s) & 1) and not ((ena >> (s - 1)) & 1):
                raise AssertionError(f"segment {s} is used and segment {s-1} is not")
            if not ((ena >> s) & 1):
                assert not ((eop >> s) & 1), f"segment {s} carries an end of frame and is not used"
            if seg_slice(mty, s, 4) and not ((eop >> s) & 1):
                raise AssertionError(f"segment {s} carries empty bytes and no end of frame")
    assert beats > 100, f"only {beats} beat(s) were accepted"
    dut._log.info("NIA_SEG_PKTGEN layout beats=%d rules hold", beats)
    await quiesce(dut)


@cocotb.test()
async def test_rate_and_counters(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 64)
    await wr(dut, A_CTL, CTL_ENABLE)
    frames, beats = await collect(dut, PRIME_BEATS)
    await wr(dut, A_CTL, 0x0)
    await ClockCycles(dut.axil_aclk, 32)
    hw_frames = await rd(dut, A_TX_FRAMES)
    hw_bytes = await rd(dut, A_TX_BYTES)
    assert hw_frames >= len(frames), \
        f"the frame counter reads {hw_frames} and the bench saw {len(frames)}"
    assert hw_bytes >= sum(len(f) for f in frames), \
        f"the byte counter reads {hw_bytes} and the bench saw {sum(len(f) for f in frames)}"
    beats_per_frame = beats / max(len(frames), 1)
    rate_hz = 1e9 / SEG_NS
    frame_rate = rate_hz / max(beats_per_frame, 1e-9)
    wire = frame_rate * (64 + 20) * 8 / 1e9
    dut._log.info("NIA_SEG_PKTGEN rate len=64 beats_per_frame=%.2f frames_per_s=%.1fM wire=%.1f Gb/s",
                  beats_per_frame, frame_rate / 1e6, wire)
    await quiesce(dut)


@cocotb.test()
async def test_limit_stops_the_stream(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 64)
    await wr(dut, A_TX_FRAME_LIMIT, 64)
    await wr(dut, A_CTL, CTL_ENABLE)
    frames, _ = await collect(dut, PRIME_BEATS)
    assert len(frames) >= 64, f"the limit of 64 produced only {len(frames)} frame(s)"
    for f in frames:
        assert len(f) == 64, f"a frame is {len(f)} bytes, expected 64"
    assert_contiguous(frames, "limit 64")
    quiet, _ = await collect(dut, 600)
    assert not quiet, f"{len(quiet)} frame(s) followed the limit"
    status = await rd(dut, A_STATUS)
    assert status & ST_DONE, f"STATUS does not report done, reads 0x{status:08x}"
    hw_frames = await rd(dut, A_TX_FRAMES)
    assert hw_frames == len(frames), \
        f"the frame counter reads {hw_frames} and {len(frames)} frame(s) reached the client"
    dut._log.info("NIA_SEG_PKTGEN limit 64 frames=%d done=1", len(frames))
    await quiesce(dut)


@cocotb.test()
async def test_no_idle_beat_at_full_rate(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 60)
    await wr(dut, A_LEN_MAX, 1518)
    await wr(dut, A_LEN_MODE, LEN_MODE_RANDOM)
    await wr(dut, A_CTL, CTL_ENABLE)
    for _ in range(PRIME_BEATS):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ena.value):
            break
    else:
        raise AssertionError("the generator never presented a beat")
    observed = 0
    carried = 0
    for _ in range(2000):
        await RisingEdge(dut.seg_clk)
        observed += 1
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ena.value):
            carried += 1
    assert carried == observed, \
        f"the generator idled: {carried} beat(s) carried data over {observed} cycle(s) with tready high"
    dut._log.info("NIA_SEG_PKTGEN occupancy %d of %d cycles carry a beat", carried, observed)
    await quiesce(dut)


@cocotb.test()
async def test_back_pressure_loses_nothing(dut):
    await start(dut)
    await wr(dut, A_LEN_MIN, 64)
    await wr(dut, A_LEN_MAX, 64)
    await wr(dut, A_CTL, CTL_ENABLE)
    frames = []
    cur = bytearray()
    started = False
    toggle = 0
    dut.tx_seg_ready.value = 1
    for _ in range(6000):
        await RisingEdge(dut.seg_clk)
        taken = int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value)
        if taken:
            dat = int(dut.tx_seg_dat.value)
            ena = int(dut.tx_seg_ena.value)
            sop = int(dut.tx_seg_sop.value)
            eop = int(dut.tx_seg_eop.value)
            mty = int(dut.tx_seg_mty.value)
            for s in range(N_SEG):
                if not (ena >> s) & 1:
                    continue
                if (sop >> s) & 1:
                    started = True
                    cur = bytearray()
                assert started, "a segment carried data before any start of frame"
                n = SEG_B - (seg_slice(mty, s, 4) if (eop >> s) & 1 else 0)
                seg = seg_slice(dat, s, SEG_W)
                for b in range(n):
                    cur.append((seg >> (b * 8)) & 0xFF)
                if (eop >> s) & 1:
                    frames.append(bytes(cur))
                    cur = bytearray()
                    started = False
        toggle = (toggle + 1) % 3
        dut.tx_seg_ready.value = 1 if toggle == 0 else 0
    dut.tx_seg_ready.value = 1
    assert len(frames) >= 8, f"only {len(frames)} frame(s) survived back pressure"
    for f in frames:
        assert len(f) == 64, f"a frame is {len(f)} bytes under back pressure"
    assert_contiguous(frames, "back pressure")
    status = await rd(dut, A_STATUS)
    assert not (status & ST_UNDERFLOW), "the client bus underflowed under back pressure"
    assert not (status & ST_OVERFLOW), "the generator overflowed its buffer under back pressure"
    dut._log.info("NIA_SEG_PKTGEN back pressure one beat in three frames=%d contiguous", len(frames))
    await quiesce(dut)
