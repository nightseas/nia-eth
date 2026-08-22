#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : test_dcmac_axis_pktgen_adapter.py
# Description : The tests of the traffic path through the adapter: a length sweep and
#               every segment tail byte exact.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os

import cocotb

from cocotb.triggers import ClockCycles

from test_dcmac_axis_pktgen import (
    A_RX_BYTES,
    A_RX_ERR_FRAMES,
    A_RX_FRAMES,
    A_RX_MISMATCH_BEATS,
    A_TX_BYTES,
    A_TX_FRAMES,
    rd,
    run_burst,
    start,
)


async def drained_burst(dut, length, frames, drain=4000):
    r = await run_burst(dut, length, frames)
    await ClockCycles(dut.axil_aclk, drain)
    r["txf"], _ = await rd(dut, A_TX_FRAMES)
    r["txb"], _ = await rd(dut, A_TX_BYTES)
    r["rxf"], _ = await rd(dut, A_RX_FRAMES)
    r["rxb"], _ = await rd(dut, A_RX_BYTES)
    r["mis"], _ = await rd(dut, A_RX_MISMATCH_BEATS)
    r["err"], _ = await rd(dut, A_RX_ERR_FRAMES)
    return r

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
SEG_BEAT_B = N_SEG * SEG_W // 8

HARDWARE_MISMATCH = list(range(65, 73)) + [76, 80, 104, 129, 1000, 1518]
HARDWARE_EXACT = [64, 88, 96, 120, 124, 126, 127, 128, 192, 256, 320, 1024]


def verdict(r):
    return r["mis"] == 0 and r["rxf"] == r["txf"] and r["rxb"] == r["txb"] and r["err"] == 0


@cocotb.test()
async def test_length_sweep_through_the_adapter(dut):
    await start(dut)
    failures = []
    for length in sorted(set(HARDWARE_MISMATCH + HARDWARE_EXACT)):
        r = await drained_burst(dut, length, 8)
        ok = verdict(r)
        dut._log.info(
            "ADPT len %4d tail %2d txf %d rxf %d txb %d rxb %d mis %d err %d %s"
            % (length, length % SEG_BEAT_B, r["txf"], r["rxf"], r["txb"], r["rxb"],
               r["mis"], r["err"], "EXACT" if ok else "MISMATCH")
        )
        if not ok:
            failures.append((length, length % SEG_BEAT_B, r["mis"]))
    if failures:
        raise AssertionError(
            "the full adapter loop is not byte exact at %d lengths: %s" % (len(failures), failures)
        )


@cocotb.test()
async def test_every_segment_tail_is_byte_exact(dut):
    await start(dut)
    failures = []
    for tail in range(0, SEG_BEAT_B):
        length = 1024 + tail
        r = await drained_burst(dut, length, 8)
        ok = verdict(r)
        dut._log.info(
            "ADPTTAIL tail %2d len %4d txf %d rxf %d txb %d rxb %d mis %d %s"
            % (tail, length, r["txf"], r["rxf"], r["txb"], r["rxb"], r["mis"],
               "EXACT" if ok else "MISMATCH")
        )
        if not ok:
            failures.append((length, tail, r["mis"]))
    if failures:
        raise AssertionError("segment tail lengths not byte exact: %s" % (failures,))
