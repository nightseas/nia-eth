# ---------------------------------------------------------------------------
# File        : test_wdt.py
# Description : The watchdog timer tests: it loads at reset and does not fire early,
#               disabled it never fires, held cleared it stays cleared, and it fires
#               exactly once per window forever.
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

CLK_NS = 4

CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
MS_DEFAULT = int(os.environ.get("MS_DEFAULT", "5"))
MS_MIN = int(os.environ.get("MS_MIN", "1"))
MS_MAX = int(os.environ.get("MS_MAX", "60000"))

WIN_CYC = MS_DEFAULT * CYC_PER_MS

print(f"NIA wdt: CYC_PER_MS={CYC_PER_MS} MS_DEFAULT={MS_DEFAULT} WIN_CYC={WIN_CYC}", flush=True)

async def setup(dut, ms=0, en=0, clear=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rstn.value = 0
    dut.ms.value = ms
    dut.en.value = en
    dut.clear.value = clear
    await ClockCycles(dut.clk, 5)
    dut.rstn.value = 1
    await ClockCycles(dut.clk, 2)

async def count_timeouts(dut, cycles):
    n = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if int(dut.timeout.value):
            n += 1
    return n

@cocotb.test()
async def test_loads_at_reset_and_does_not_fire_early(dut):
    await setup(dut, ms=0, en=1, clear=0)
    early = await count_timeouts(dut, WIN_CYC - 4)
    assert early == 0, (
        f"the window fired {early} time(s) before one full window ({WIN_CYC} cycles) had elapsed - "
        "the counter was not loaded as it started"
    )

@cocotb.test()
async def test_disabled_never_fires(dut):
    await setup(dut, ms=0, en=0, clear=0)
    n = await count_timeouts(dut, 4 * WIN_CYC)
    assert n == 0, f"a disabled watchdog fired {n} times"
    assert int(dut.running.value) == 0

@cocotb.test()
async def test_clear_level_holds_it_cleared(dut):
    await setup(dut, ms=0, en=1, clear=1)
    n = await count_timeouts(dut, 5 * WIN_CYC)
    assert n == 0, f"a cleared watchdog fired {n} times"
    assert int(dut.running.value) == 0, "running should be low while held cleared"

@cocotb.test()
async def test_fires_after_exactly_one_window(dut):
    await setup(dut, ms=0, en=1, clear=0)
    n = 0
    for _ in range(3 * WIN_CYC):
        await RisingEdge(dut.clk)
        n += 1
        if int(dut.timeout.value):
            break
    assert abs(n - WIN_CYC) <= 3, (
        f"fired after {n} cycles, expected {WIN_CYC} = MS_DEFAULT({MS_DEFAULT}) x "
        f"CYC_PER_MS({CYC_PER_MS})"
    )

@cocotb.test()
async def test_fires_forever_one_per_window(dut):
    await setup(dut, ms=0, en=1, clear=0)
    n = await count_timeouts(dut, 5 * WIN_CYC + WIN_CYC // 2)
    assert 4 <= n <= 6, f"{n} timeouts over ~5 windows - expected one per window, forever"

@cocotb.test()
async def test_clear_mid_window_restarts_the_full_window(dut):
    await setup(dut, ms=0, en=1, clear=0)
    await ClockCycles(dut.clk, WIN_CYC // 2)
    dut.clear.value = 1
    await ClockCycles(dut.clk, 4)
    dut.clear.value = 0
    early = await count_timeouts(dut, WIN_CYC - 8)
    assert early == 0, (
        f"fired {early} time(s) within one window of the clear being released - the window was "
        "resumed rather than restarted"
    )

@cocotb.test()
async def test_zero_ms_means_the_default(dut):
    await setup(dut, ms=0, en=1, clear=0)
    early = await count_timeouts(dut, WIN_CYC // 2)
    assert early == 0, "ms=0 made the watchdog a reset generator"

@cocotb.test()
async def test_remaining_counts_down_and_reloads(dut):
    await setup(dut, ms=0, en=1, clear=0)
    await ClockCycles(dut.clk, 2)
    a = int(dut.remaining.value)
    await ClockCycles(dut.clk, WIN_CYC // 4)
    b = int(dut.remaining.value)
    assert b < a, f"remaining did not count down: {a} -> {b}"
    assert b > 0
    for _ in range(2 * WIN_CYC):
        await RisingEdge(dut.clk)
        if int(dut.timeout.value):
            break
    await ClockCycles(dut.clk, 2)
    c = int(dut.remaining.value)
    assert c > b, f"remaining did not reload after the timeout: {c}"
