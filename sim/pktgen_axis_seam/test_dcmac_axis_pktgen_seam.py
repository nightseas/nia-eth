#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : test_dcmac_axis_pktgen_seam.py
# Description : The tests of the traffic path at the client boundary: a length sweep and
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

from test_dcmac_axis_pktgen import run_burst, start

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
        r = await run_burst(dut, length, 8)
        ok = verdict(r)
        dut._log.info(
            "SEAM len %4d tail %2d txf %d rxf %d txb %d rxb %d mis %d err %d %s"
            % (length, length % SEG_BEAT_B, r["txf"], r["rxf"], r["txb"], r["rxb"],
               r["mis"], r["err"], "EXACT" if ok else "MISMATCH")
        )
        if not ok:
            failures.append((length, length % SEG_BEAT_B, r["mis"]))
    if failures:
        raise AssertionError(
            "the adapter loop is not byte exact at %d lengths: %s" % (len(failures), failures)
        )


@cocotb.test()
async def test_every_segment_tail_is_byte_exact(dut):
    await start(dut)
    failures = []
    for tail in range(0, SEG_BEAT_B):
        length = 1024 + tail
        r = await run_burst(dut, length, 8)
        ok = verdict(r)
        dut._log.info(
            "SEAMTAIL tail %2d len %4d txf %d rxf %d txb %d rxb %d mis %d %s"
            % (tail, length, r["txf"], r["rxf"], r["txb"], r["rxb"], r["mis"],
               "EXACT" if ok else "MISMATCH")
        )
        if not ok:
            failures.append((length, tail, r["mis"]))
    if failures:
        raise AssertionError("segment tail lengths not byte exact: %s" % (failures,))
