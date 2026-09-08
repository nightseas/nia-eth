#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : test_dcmac_seg_pack.py
# Description : The cocotb set for the transmit segment packer. It drives frames into the
#               store and forward frame FIFO in front of the packer, rebuilds every frame
#               from the segmented interface, and asserts the four properties the DCMAC
#               transmit interface and the packing mechanism require: byte exactness, a
#               segment valid that never goes low between a start and an end of packet, a
#               start of packet on a segment other than zero where the previous frame ended
#               on the preceding segment, and a segment count per frame of
#               ceil(length/SEG_B) with no wasted segmented cycle.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

N_SEG = int(os.environ.get("N_SEG", "4"))
SEG_W = int(os.environ.get("SEG_W", "128"))
DATA_W = int(os.environ.get("DATA_W", "1024"))
SEG_B = SEG_W // 8
BEAT_B = DATA_W // 8
LEN_MIN = 64
LEN_MAX = int(os.environ.get("MAX_LEN", "9018"))


def note(dut, text):
    dut._log.info("NIA_SEG_PACK %s", text)


async def reset(dut):
    dut.rstn.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.tx_seg_ready.value = 1
    for _ in range(16):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)


def frame_bytes(index, length):
    return bytes(((index * 131 + i * 17 + (i >> 8) * 7) & 0xFF) for i in range(length))


async def drive_frames(dut, frames, gap_every=0):
    """Present each frame as whole DATA_W beats. A frame is never gapped mid-frame, which
    is the contract the store and forward frame FIFO in front of the packer provides."""
    for fi, payload in enumerate(frames):
        beats = [payload[i:i + BEAT_B] for i in range(0, len(payload), BEAT_B)]
        for bi, beat in enumerate(beats):
            word = int.from_bytes(beat.ljust(BEAT_B, b"\x00"), "little")
            dut.s_axis_tdata.value = word
            dut.s_axis_tkeep.value = (1 << len(beat)) - 1
            dut.s_axis_tlast.value = 1 if bi == len(beats) - 1 else 0
            dut.s_axis_tuser.value = 0
            dut.s_axis_tvalid.value = 1
            while True:
                await ReadOnly()
                taken = dut.s_axis_tready.value == 1
                await RisingEdge(dut.clk)
                if taken:
                    break
        if gap_every and (fi % gap_every) == (gap_every - 1):
            dut.s_axis_tvalid.value = 0
            dut.s_axis_tlast.value = 0
            for _ in range(random.randint(1, 4)):
                await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


class SegmentSink:
    """Rebuilds frames from the segmented interface and enforces the placement rules."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []
        self.cur = bytearray()
        self.open_frame = False
        self.beats = 0
        self.active_beats = 0
        self.segments = 0
        self.frame_segments = []
        self.cur_segments = 0
        self.sop_positions = []
        self.errors = []
        self.last_seg_was_eop = False

    def check(self, cond, text):
        if not cond:
            self.errors.append(text)

    def sample(self, valid, ena, sop, eop, err, mty, dat):
        self.beats += 1
        if not valid or ena == 0:
            self.check(not self.open_frame,
                       "segment valid low while a frame is open, at segmented cycle %d"
                       % self.beats)
            return
        self.active_beats += 1

        bits = [(ena >> k) & 1 for k in range(N_SEG)]
        first_zero = N_SEG
        for k in range(N_SEG):
            if bits[k] == 0:
                first_zero = k
                break
        for k in range(first_zero, N_SEG):
            self.check(bits[k] == 0,
                       "segment enable is not a contiguous run from segment 0: ena=0x%x at "
                       "segmented cycle %d" % (ena, self.beats))
        count = first_zero

        if count < N_SEG:
            self.check((eop >> (count - 1)) & 1,
                       "segment valid deasserts at segment %d without an end of packet "
                       "there, ena=0x%x eop=0x%x at segmented cycle %d"
                       % (count, ena, eop, self.beats))

        for k in range(count):
            seg = (dat >> (k * SEG_W)) & ((1 << SEG_W) - 1)
            is_sop = (sop >> k) & 1
            is_eop = (eop >> k) & 1
            empty = (mty >> (k * 4)) & 0xF

            if is_sop:
                self.check(not self.open_frame,
                           "start of packet on segment %d while a frame is open, at "
                           "segmented cycle %d" % (k, self.beats))
                self.cur = bytearray()
                self.cur_segments = 0
                self.open_frame = True
                self.sop_positions.append(k)
                if k > 0:
                    self.check(self.last_seg_was_eop,
                              "start of packet on segment %d is not immediately preceded by "
                              "an end of packet on segment %d, at segmented cycle %d"
                              % (k, k - 1, self.beats))
            else:
                self.check(self.open_frame,
                           "segment %d carries data with no frame open, at segmented cycle "
                           "%d" % (k, self.beats))

            take = SEG_B - empty if is_eop else SEG_B
            self.check(1 <= take <= SEG_B,
                       "empty count %d on segment %d is out of range at segmented cycle %d"
                       % (empty, k, self.beats))
            self.cur += seg.to_bytes(SEG_B, "little")[:take]
            self.cur_segments += 1
            self.segments += 1
            self.last_seg_was_eop = bool(is_eop)

            if is_eop:
                self.frames.append(bytes(self.cur))
                self.frame_segments.append(self.cur_segments)
                self.open_frame = False
                self.cur = bytearray()


async def run_sink(dut, sink, cycles):
    for _ in range(cycles):
        await ReadOnly()
        if dut.tx_seg_ready.value == 1:
            sink.sample(
                int(dut.tx_seg_valid.value),
                int(dut.tx_seg_ena.value),
                int(dut.tx_seg_sop.value),
                int(dut.tx_seg_eop.value),
                int(dut.tx_seg_err.value),
                int(dut.tx_seg_mty.value),
                int(dut.tx_seg_dat.value),
            )
        await RisingEdge(dut.clk)


def report(dut, sink, expect, tag):
    assert not sink.errors, "%s: %d rule violation(s), first: %s" % (
        tag, len(sink.errors), sink.errors[0])
    assert len(sink.frames) == len(expect), \
        "%s: rebuilt %d frames, drove %d" % (tag, len(sink.frames), len(expect))
    for i, (got, want) in enumerate(zip(sink.frames, expect)):
        assert got == want, \
            "%s: frame %d differs: %d bytes rebuilt against %d driven" % (
                tag, i, len(got), len(want))
    for i, (segs, want) in enumerate(zip(sink.frame_segments, expect)):
        need = (len(want) + SEG_B - 1) // SEG_B
        assert segs == need, \
            "%s: frame %d of %d bytes occupies %d segments against ceil(%d/%d)=%d" % (
                tag, i, len(want), segs, len(want), SEG_B, need)
    note(dut, "%s N_SEG=%d DATA_W=%d frames=%d segments=%d active_cycles=%d "
              "sop_positions=%s" % (
                  tag, N_SEG, DATA_W, len(sink.frames), sink.segments, sink.active_beats,
                  sorted(set(sink.sop_positions))))


async def exercise(dut, lengths, gap_every=0, slack=400):
    expect = [frame_bytes(i, n) for i, n in enumerate(lengths)]
    sink = SegmentSink(dut)
    total_segments = sum((n + SEG_B - 1) // SEG_B for n in lengths)
    total_beats = sum((n + BEAT_B - 1) // BEAT_B for n in lengths)
    cycles = 4 * (total_segments // N_SEG + total_beats) + slack + 40 * len(lengths)
    sink_task = cocotb.start_soon(run_sink(dut, sink, cycles))
    await drive_frames(dut, expect, gap_every)
    await sink_task
    return sink, expect


@cocotb.test()
async def test_fixed_length_is_byte_exact_and_packed(dut):
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    for length in (64, 65, 96, 97, 128, 129, 257, 385, 1518):
        await reset(dut)
        sink, expect = await exercise(dut, [length] * 48)
        report(dut, sink, expect, "fixed len=%d" % length)


@cocotb.test()
async def test_start_of_packet_reaches_a_segment_other_than_zero(dut):
    """A frame on an unsegmented stream begins at byte 0 of a beat, so a start of packet can
    reach a segment other than segment 0 only where one beat spans more than one segmented
    cycle, that is where SLOTS exceeds N_SEG. At the 400G geometry SLOTS equals N_SEG, one
    beat is exactly one segmented cycle and one stream starts at most one frame per cycle, so
    every start of packet is on segment 0 and that is the one stream limit of open item 16.1
    rather than a packing failure."""
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    await reset(dut)
    sink, expect = await exercise(dut, [65] * 96)
    report(dut, sink, expect, "sop placement")
    seen = sorted(set(sink.sop_positions))
    slots = BEAT_B // SEG_B
    if slots > N_SEG:
        assert any(p > 0 for p in seen), (
            "one beat carries %d slots against %d segments per cycle, so a start of packet "
            "shall reach a segment other than 0, but every one landed on segment 0: "
            "positions=%s" % (slots, N_SEG, seen))
    else:
        assert seen == [0], (
            "one beat carries %d slots against %d segments per cycle, so every start of "
            "packet is on segment 0: positions=%s" % (slots, N_SEG, seen))


@cocotb.test()
async def test_random_lengths_are_byte_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    random.seed(0xC0FFEE ^ N_SEG)
    await reset(dut)
    lengths = [random.randint(LEN_MIN, min(LEN_MAX, 1518)) for _ in range(96)]
    sink, expect = await exercise(dut, lengths)
    report(dut, sink, expect, "random")


@cocotb.test()
async def test_maximum_length_is_byte_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    await reset(dut)
    sink, expect = await exercise(dut, [LEN_MAX, 64, LEN_MAX, 65, LEN_MAX])
    report(dut, sink, expect, "maximum len=%d" % LEN_MAX)


@cocotb.test()
async def test_input_gaps_between_frames_lose_nothing(dut):
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    random.seed(0x5EED ^ N_SEG)
    await reset(dut)
    lengths = [random.randint(LEN_MIN, 300) for _ in range(64)]
    sink, expect = await exercise(dut, lengths, gap_every=3)
    report(dut, sink, expect, "input gaps")


@cocotb.test()
async def test_segment_back_pressure_loses_nothing(dut):
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    random.seed(0xBEEF ^ N_SEG)
    await reset(dut)

    async def pulse_ready():
        while True:
            dut.tx_seg_ready.value = 1
            for _ in range(random.randint(3, 9)):
                await RisingEdge(dut.clk)
            dut.tx_seg_ready.value = 0
            for _ in range(random.randint(1, 3)):
                await RisingEdge(dut.clk)

    ready_task = cocotb.start_soon(pulse_ready())
    lengths = [random.randint(LEN_MIN, 400) for _ in range(64)]
    sink, expect = await exercise(dut, lengths, slack=3000)
    ready_task.kill()
    dut.tx_seg_ready.value = 1
    report(dut, sink, expect, "segment back pressure")


@cocotb.test()
async def test_rate_at_the_worst_length(dut):
    """Compares the achieved segmented cycles per frame with the bound the geometry sets. Two
    caps apply. The segment cap is ceil(length/SEG_B)/N_SEG cycles per frame. The input beat
    cap is ceil(length/BEAT_B) cycles per frame, because a frame on an unsegmented stream
    begins at byte 0 of a beat and one stream presents at most one beat per cycle. The bound
    is the larger of the two, and reaching it means no segmented cycle is wasted."""
    cocotb.start_soon(Clock(dut.clk, 2.558, units="ns").start())
    for length in (64, 65, 129, 257):
        await reset(dut)
        sink, expect = await exercise(dut, [length] * 128)
        report(dut, sink, expect, "rate len=%d" % length)
        segment_bound = len(expect) * ((length + SEG_B - 1) // SEG_B) / N_SEG
        beat_bound = len(expect) * ((length + BEAT_B - 1) // BEAT_B)
        bound = max(segment_bound, beat_bound)
        which = "segment" if segment_bound >= beat_bound else "input beat"
        note(dut, "rate len=%d segments=%d active_cycles=%d bound_cycles=%.1f (%s) "
                  "fill=%.3f" % (length, sink.segments, sink.active_beats, bound, which,
                                 bound / max(1, sink.active_beats)))
        assert sink.active_beats <= bound + 2, (
            "len=%d used %d segmented cycles against the %s bound of %.1f, so cycles are "
            "being wasted" % (length, sink.active_beats, which, bound))
