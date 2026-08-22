# ---------------------------------------------------------------------------
# File        : test_gt_rst_req_gate.py
# Description : The reset gate tests: the pulse width is independent of the host, a held
#               level gives exactly one pulse, rearming needs a write back to zero, and
#               the request is refused while the reset is not done or the sequencer is
#               busy.
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
from cocotb.triggers import RisingEdge, Timer

PULSE = int(os.environ.get("GATE_PULSE_CYC", "16"))
SETTLE = int(os.environ.get("GATE_SETTLE_CYC", "20"))
TMO = int(os.environ.get("GATE_DONE_TMO_CYC", "200"))
EN_GATE = int(os.environ.get("GATE_EN_GATE", "1"))

S_IDLE, S_PULSE, S_WAITD, S_HOLD = 0, 1, 2, 3

async def start(dut, done=1, busy=0):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    dut.req_level.value = 0
    dut.gt_reset_done.value = done
    dut.seq_busy.value = busy
    dut.clr_status.value = 0
    dut.rstn.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

async def measure_pulse(dut, max_cyc):
    high = 0
    seen = False
    for _ in range(max_cyc):
        await RisingEdge(dut.clk)
        if int(dut.req_pulse.value):
            high += 1
            seen = True
        elif seen:
            break
    return high

async def gt_responder(dut, down_cyc=6):
    while True:
        await RisingEdge(dut.clk)
        if int(dut.req_pulse.value):
            while int(dut.req_pulse.value):
                await RisingEdge(dut.clk)
            dut.gt_reset_done.value = 0
            for _ in range(down_cyc):
                await RisingEdge(dut.clk)
            dut.gt_reset_done.value = 1

@cocotb.test()
async def test_ns41_pulse_width_is_independent_of_the_host(dut):
    await start(dut)

    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0
    w_short = await measure_pulse(dut, PULSE * 4)
    assert w_short == PULSE, ": short write gave %d cycles, expected %d" % (w_short, PULSE)

    dut.gt_reset_done.value = 0
    await RisingEdge(dut.clk)
    dut.gt_reset_done.value = 1
    for _ in range(SETTLE + 40):
        await RisingEdge(dut.clk)

    dut.req_level.value = 1
    w_held = await measure_pulse(dut, PULSE * 20)
    assert w_held == PULSE, ": held write gave %d cycles, expected %d" % (w_held, PULSE)
    assert w_held == w_short, ": host hold time changed the GT assertion (%d vs %d)" % (
        w_held, w_short)
    dut.req_level.value = 0
    dut._log.info(" PASS: pulse = %d cycles for a 1-cycle write AND for a held one" % PULSE)

@cocotb.test()
async def test_ns41_held_level_gives_exactly_one_pulse(dut):
    await start(dut)
    cocotb.start_soon(gt_responder(dut))
    dut.req_level.value = 1

    edges = 0
    high = 0
    prev = 0
    for _ in range(4 * (PULSE + SETTLE + 40)):
        await RisingEdge(dut.clk)
        cur = int(dut.req_pulse.value)
        if cur:
            high += 1
        if cur and not prev:
            edges += 1
        prev = cur
    assert int(dut.sts_stuck.value) == 0, (
        "the responder is not working - the gate latched `stuck`, so this test would be measuring "
        " and not  (this is exactly the hole M12 exposed)")
    assert edges == 1, ": a held level produced %d pulses, expected exactly 1" % edges
    assert high == PULSE, (
        ": a held level kept the GT asserted for %d cycles, expected %d. THIS IS THE 200 ms "
        "DEATH: the request was never released by hardware." % (high, PULSE))
    dut._log.info(" PASS: held forever, with a REAL GT responder => 1 pulse of exactly %d "
                  "cycles" % PULSE)

@cocotb.test()
async def test_ns41_rearm_needs_a_write_back_to_zero(dut):
    await start(dut)
    dut.req_level.value = 1
    assert await measure_pulse(dut, PULSE * 4) == PULSE

    dut.gt_reset_done.value = 0
    await RisingEdge(dut.clk)
    dut.gt_reset_done.value = 1
    for _ in range(SETTLE + 40):
        await RisingEdge(dut.clk)
    assert int(dut.sts_state.value) == S_IDLE, "gate did not return to IDLE"

    dut.req_level.value = 0
    await RisingEdge(dut.clk)
    dut.req_level.value = 1
    w = await measure_pulse(dut, PULSE * 4)
    assert w == PULSE, ": re-arm after a write to 0 gave %d cycles" % w
    dut._log.info(" PASS: re-arm requires 1 -> 0 -> 1")

@cocotb.test()
async def test_ns42_refused_while_reset_done_low(dut):
    await start(dut, done=0)
    dut.req_level.value = 1
    for _ in range(PULSE * 4):
        await RisingEdge(dut.clk)
        assert int(dut.req_pulse.value) == 0, ": pulsed with reset_done LOW"
    assert int(dut.sts_refused.value) == 1, ": refusal not reported"
    assert int(dut.sts_refuse_cnt.value) == 1, ": refusal not counted"
    dut._log.info(" PASS: reset_done low => 0 GT assertions, refusal counted")

@cocotb.test()
async def test_ns42_refused_while_seq_busy(dut):
    await start(dut, busy=1)
    dut.req_level.value = 1
    for _ in range(PULSE * 4):
        await RisingEdge(dut.clk)
        assert int(dut.req_pulse.value) == 0, ": pulsed while the sequencer was busy"
    assert int(dut.sts_refuse_cnt.value) == 1

    dut.req_level.value = 0
    await RisingEdge(dut.clk)
    dut.seq_busy.value = 0
    await RisingEdge(dut.clk)
    dut.req_level.value = 1
    assert await measure_pulse(dut, PULSE * 4) == PULSE, ": still refused after busy fell"
    dut._log.info(" PASS: refused while busy, accepted after")

@cocotb.test()
async def test_ns42_a_refusal_is_dropped_not_queued(dut):
    await start(dut)
    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0
    await RisingEdge(dut.clk)
    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0

    edges = 0
    prev = int(dut.req_pulse.value)
    for _ in range(PULSE + TMO + SETTLE + 200):
        await RisingEdge(dut.clk)
        cur = int(dut.req_pulse.value)
        if cur and not prev:
            edges += 1
        prev = cur
    assert edges == 0, ": a mid-pulse request was QUEUED and fired later (%d)" % edges
    assert int(dut.sts_refused.value) == 1, ": the dropped request was not reported"
    dut._log.info(" PASS: mid-pulse request dropped, not deferred")

@cocotb.test()
async def test_ns43_holdoff_waits_for_done_to_return(dut):
    await start(dut)
    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0
    assert await measure_pulse(dut, PULSE * 4) == PULSE

    dut.gt_reset_done.value = 0
    for _ in range(30):
        await RisingEdge(dut.clk)
    assert int(dut.sts_state.value) == S_WAITD, ": not waiting for done"

    dut.req_level.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        assert int(dut.req_pulse.value) == 0, ": pulsed while the GT was still resetting"
    dut.req_level.value = 0
    assert int(dut.sts_refuse_cnt.value) >= 1

    dut.gt_reset_done.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.sts_state.value) == S_HOLD, ": did not enter the settle window"
    for _ in range(SETTLE + 8):
        await RisingEdge(dut.clk)
    assert int(dut.sts_state.value) == S_IDLE, ": never left the settle window"
    assert int(dut.sts_stuck.value) == 0, ": a healthy GT was reported stuck"
    dut._log.info(" PASS: holdoff exits on done low->high + %d settle cycles" % SETTLE)

@cocotb.test()
async def test_ns43_stuck_is_latched_and_no_further_pulse_is_issued(dut):
    await start(dut)
    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0
    assert await measure_pulse(dut, PULSE * 4) == PULSE

    dut.gt_reset_done.value = 0
    for _ in range(TMO + 20):
        await RisingEdge(dut.clk)
    assert int(dut.sts_stuck.value) == 1, ": `stuck` never latched after the timeout"

    dut.gt_reset_done.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    for _ in range(3):
        dut.req_level.value = 1
        for _ in range(PULSE + 4):
            await RisingEdge(dut.clk)
            assert int(dut.req_pulse.value) == 0, ": pulsed again after `stuck`"
        dut.req_level.value = 0
        await RisingEdge(dut.clk)
    dut._log.info(" PASS: stuck latched, and it refuses forever after")

@cocotb.test()
async def test_ns45_refusals_are_counted_and_clearable(dut):
    await start(dut, done=0)
    for i in range(20):
        dut.req_level.value = 1
        await RisingEdge(dut.clk)
        dut.req_level.value = 0
        await RisingEdge(dut.clk)
    cnt = int(dut.sts_refuse_cnt.value)
    assert cnt == 0xF, ": count did not saturate at 0xF (got %d) - it wrapped" % cnt
    assert int(dut.sts_refused.value) == 1

    dut.clr_status.value = 1
    await RisingEdge(dut.clk)
    dut.clr_status.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.sts_refuse_cnt.value) == 0, ": clear did not clear the count"
    assert int(dut.sts_refused.value) == 0, ": clear did not clear the sticky bit"
    dut._log.info(" PASS: refusals counted, saturating, clearable")

@cocotb.test(skip=(EN_GATE != 0))
async def test_control_arm_en_gate_0_is_a_pass_through(dut):
    await start(dut)
    dut.req_level.value = 1
    for _ in range(PULSE * 6):
        await RisingEdge(dut.clk)
    assert int(dut.req_pulse.value) == 1, \
        "the control variant did not reproduce the raw level - EN_GATE=0 is not a control"
    dut.req_level.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.req_pulse.value) == 0
    dut._log.info("CONTROL PASS: EN_GATE=0 is the pre- raw level (held as long as the host holds)")

@cocotb.test(skip=(EN_GATE == 0))
async def test_ns44_gate_holds_no_static_state(dut):
    await start(dut, done=0)
    dut.req_level.value = 1
    await RisingEdge(dut.clk)
    dut.req_level.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.sts_refuse_cnt.value) == 1
    dut.rstn.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    assert int(dut.sts_refuse_cnt.value) == 0, ": state survived a reset"
    assert int(dut.sts_state.value) == S_IDLE
    assert int(dut.sts_stuck.value) == 0
    dut._log.info(" PASS: all state is per-instance and reset-clearable")
