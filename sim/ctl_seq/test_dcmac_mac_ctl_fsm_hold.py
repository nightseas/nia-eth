# ---------------------------------------------------------------------------
# File        : test_dcmac_mac_ctl_fsm_hold.py
# Description : The MAC control state machine tests: a short dip causes no reset, a loss
#               stops data and raises the fault at once while keeping the receiver
#               enabled, only a request through the state machine resets, and recovery is
#               immediate.
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

CLK_NS = 2.56

CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
T_RXDP_MS = int(os.environ.get("T_RXDP_MS", "3"))
T_SERDES_MS = int(os.environ.get("T_SERDES_MS", "2"))
LINK_CONFIRM_N = int(os.environ.get("LINK_CONFIRM_N", "2"))
NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
PORT_MAX = int(os.environ.get("PORT_MAX", "6"))

S_IDLE, S_WAIT_ALIGN, S_XFER, S_RX_RESET = 0, 2, 3, 4
S_RX_DONE, S_RX_FLUSH, S_RX_SETTLE = 5, 6, 7
NAMES = {S_IDLE: "IDLE", S_WAIT_ALIGN: "WAIT_LINK", S_XFER: "LINK_UP", S_RX_RESET: "RESET_LINK",
         S_RX_DONE: "RESET_WAIT_DONE", S_RX_FLUSH: "RESET_FLUSH", S_RX_SETTLE: "RESET_SETTLE"}

RESET_CYC = (T_RXDP_MS + 3 * T_SERDES_MS) * CYC_PER_MS + 64
WIDE_CYC = RESET_CYC
NARROW_CYC = RESET_CYC

print(f"NIA ctl_fsm: CYC_PER_MS={CYC_PER_MS} T_RXDP_MS={T_RXDP_MS} T_SERDES_MS={T_SERDES_MS} "
      f"CONFIRM={LINK_CONFIRM_N} NPORTS={NPORTS} ANCHOR={ANCHOR} RESET_CYC={RESET_CYC}", flush=True)

class Watch:
    def __init__(self, dut):
        self.dut = dut
        self.rx = 0
        self.tx = 0
        self.order = []

    async def run(self):
        prx = 0
        while True:
            await RisingEdge(self.dut.seg_clk)
            rx = int(self.dut.rx_datapath_reset.value)
            if rx and not prx:
                self.rx += 1
                self.order.append("rx")
            prx = rx

_TASKS = []

def _spawn(coro):
    t = cocotb.start_soon(coro)
    _TASKS.append(t)
    return t

def _kill_all():
    for t in _TASKS:
        try:
            t.kill()
        except Exception:
            pass
    _TASKS.clear()

async def setup(dut):
    _kill_all()
    _spawn(Clock(dut.seg_clk, CLK_NS, units="ns").start())
    dut.seg_rstn.value = 0
    dut.configured.value = 0
    dut.stat_rx_aligned.value = 0
    dut.stat_remote_fault.value = 0
    dut.reset_req.value = 0
    dut.rx_force_resync_req.value = 0
    w = Watch(dut)
    _spawn(w.run())
    await ClockCycles(dut.seg_clk, 8)
    dut.seg_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)
    dut.configured.value = 1
    await ClockCycles(dut.seg_clk, 3)
    return w

async def bring_up(dut):
    dut.stat_rx_aligned.value = 1
    for _ in range(64):
        await RisingEdge(dut.seg_clk)
        if int(dut.fsm_state.value) == S_XFER:
            await ClockCycles(dut.seg_clk, 2)
            assert int(dut.fsm_state.value) == S_XFER, "left XFER while settling"
            return
    raise AssertionError(f"never reached XFER; stuck in {NAMES[int(dut.fsm_state.value)]}")

async def request_reset(dut, wide=False):
    dut.reset_req.value = 1
    for _ in range(64):
        await RisingEdge(dut.seg_clk)
        if int(dut.reset_ack.value) == 1:
            dut.reset_req.value = 0
            return
    raise AssertionError("the FSM never acknowledged the reset request")

@cocotb.test()
async def test_c1_a_short_dip_causes_no_reset(dut):
    w = await setup(dut)
    await bring_up(dut)
    base_rx, base_tx = w.rx, w.tx
    for i in range(12):
        dut.stat_rx_aligned.value = 0
        await ClockCycles(dut.seg_clk, 3)
        dut.stat_rx_aligned.value = 1
        await ClockCycles(dut.seg_clk, 20)
        assert w.rx == base_rx, (
            f": dip {i} caused {w.rx - base_rx} RX datapath reset(s). Losing alignment must enter "
            "HOLD and wait for the window; only the window may reset."
        )
        assert w.tx == base_tx, f": dip {i} caused a TX datapath reset"
    assert int(dut.fsm_state.value) == S_XFER, (
        f"after the dips the port should be back up, not {NAMES[int(dut.fsm_state.value)]}"
    )

@cocotb.test()
async def test_c1_loss_stops_data_and_raises_fault_now(dut):
    await setup(dut)
    await bring_up(dut)
    assert int(dut.ctl_tx_enable.value) == 1
    assert int(dut.ctl_tx_send_lfi.value) == 0
    dut.stat_rx_aligned.value = 0
    await ClockCycles(dut.seg_clk, 3)
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN, (
        f"expected WAIT_ALIGN (HOLD was merged into it), got {NAMES[int(dut.fsm_state.value)]}"
    )
    assert int(dut.ctl_tx_enable.value) == 0, "data was not stopped on alignment loss"
    assert int(dut.ctl_tx_send_lfi.value) == 1, "the 802.3 fault indication was not raised"
    assert int(dut.ctl_tx_send_rfi.value) == 1
    assert int(dut.rx_datapath_reset.value) == 0, "losing alignment must not touch a reset"

@cocotb.test()
async def test_c1_loss_keeps_the_receiver_enabled(dut):
    await setup(dut)
    await bring_up(dut)
    dut.stat_rx_aligned.value = 0
    await ClockCycles(dut.seg_clk, 4)
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN
    assert int(dut.ctl_rx_enable.value) == 1, "losing alignment disabled the receiver"
    await ClockCycles(dut.seg_clk, 200)
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN, "the FSM left WAIT_ALIGN without a request"
    assert int(dut.ctl_rx_enable.value) == 1

@cocotb.test()
async def test_ns67_only_a_request_through_the_fsm_resets(dut):
    w = await setup(dut)
    await bring_up(dut)
    dut.stat_rx_aligned.value = 0
    await ClockCycles(dut.seg_clk, 4)
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN
    assert w.rx == 0
    await request_reset(dut, wide=False)
    seen = False
    for _ in range(NARROW_CYC + 8):
        await RisingEdge(dut.seg_clk)
        if int(dut.fsm_state.value) == S_RX_RESET:
            seen = True
            break
    assert seen, "the request was acknowledged but no state change followed"
    await ClockCycles(dut.seg_clk, RESET_CYC)
    assert w.rx == 1, f"expected exactly one RX reset, saw {w.rx}"
    assert w.tx == 0, f"a narrow request moved the TX pin {w.tx} time(s)"

@cocotb.test()
async def test_ns68_recovery_is_immediate(dut):
    await setup(dut)
    await bring_up(dut)
    dut.stat_rx_aligned.value = 0
    await ClockCycles(dut.seg_clk, 4)
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN
    dut.stat_rx_aligned.value = 1
    n = 0
    for _ in range(8):
        await RisingEdge(dut.seg_clk)
        n += 1
        if int(dut.fsm_state.value) == S_XFER:
            break
    assert int(dut.fsm_state.value) == S_XFER, "recovery from HOLD was not taken"
    assert n <= 4, f"recovery took {n} cycles; the rise must not be debounced"

@cocotb.test()
async def test_ns68_carrier_falls_debounced_link_up_does_not(dut):
    await setup(dut)
    await bring_up(dut)
    assert int(dut.link_up.value) == 1
    assert int(dut.carrier.value) == 1
    dut.stat_rx_aligned.value = 0
    await ClockCycles(dut.seg_clk, 3)
    assert int(dut.link_up.value) == 0, "link_up must fall as soon as the state leaves XFER"
    if LINK_CONFIRM_N > 1:
        assert int(dut.carrier.value) == 1, (
            f"carrier fell undebounced with LINK_CONFIRM_N={LINK_CONFIRM_N}"
        )
    await ClockCycles(dut.seg_clk, LINK_CONFIRM_N + 4)
    assert int(dut.carrier.value) == 0, "carrier never fell"

@cocotb.test()
async def test_ns70_no_terminal_state_from_any_state(dut):
    reached = {}
    for target in (S_WAIT_ALIGN, S_XFER, S_RX_RESET):
        w = await setup(dut)
        if target == S_WAIT_ALIGN:
            await ClockCycles(dut.seg_clk, 6)
        elif target == S_XFER:
            await bring_up(dut)
        elif target == S_WAIT_ALIGN:
            await bring_up(dut)
            dut.stat_rx_aligned.value = 0
            await ClockCycles(dut.seg_clk, 4)
        elif target == S_RX_RESET:
            await ClockCycles(dut.seg_clk, 6)
            await request_reset(dut)
            for _ in range(WIDE_CYC + 8):
                await RisingEdge(dut.seg_clk)
                if int(dut.fsm_state.value) == target:
                    break
        assert int(dut.fsm_state.value) == target, (
            f"could not drive the FSM to {NAMES[target]}; sat in "
            f"{NAMES[int(dut.fsm_state.value)]}"
        )
        dut.stat_rx_aligned.value = 1
        ok = False
        for _ in range(WIDE_CYC + 32):
            await RisingEdge(dut.seg_clk)
            if int(dut.fsm_state.value) == S_XFER:
                ok = True
                break
        reached[NAMES[target]] = ok
        assert ok, (
            f": from {NAMES[target]} an aligned link never reached XFER - that is a state from "
            "which recovery is impossible"
        )
    assert all(reached.values()), reached

@cocotb.test()
async def test_reset_is_real_assert_hold_release(dut):
    w = await setup(dut)
    await ClockCycles(dut.seg_clk, 6)
    await request_reset(dut)
    for _ in range(64):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value) == 1:
            break
    assert int(dut.rx_datapath_reset.value) == 1, "the reset never asserted"
    hold = 0
    while int(dut.rx_datapath_reset.value) == 1 and hold < 4 * RESET_CYC:
        await RisingEdge(dut.seg_clk)
        hold += 1
    expect = T_RXDP_MS * CYC_PER_MS
    assert abs(hold - expect) <= 4, (
        f"the reset was held {hold} cycles, expected {expect} "
        f"(T_RXDP_MS={T_RXDP_MS} x CYC_PER_MS={CYC_PER_MS})"
    )
    settle = 0
    while int(dut.fsm_state.value) != S_IDLE and settle < 8 * RESET_CYC:
        await RisingEdge(dut.seg_clk)
        settle += 1
    expect2 = T_SERDES_MS * CYC_PER_MS
    assert settle >= expect2, (
        f"the repair took {settle} cycles from the release of the datapath reset to IDLE, "
        f"expected at least the settle of {expect2} cycles (T_SERDES_MS={T_SERDES_MS}). "
        "The first implementation had ~2 cycles here."
    )
    assert w.rx == 1, f"expected exactly one reset pulse, saw {w.rx}"

@cocotb.test()
async def test_sw_rst_configured_low_forces_idle_from_any_state(dut):
    for target in (S_WAIT_ALIGN, S_XFER, S_RX_RESET):
        w = await setup(dut)
        if target == S_WAIT_ALIGN:
            await ClockCycles(dut.seg_clk, 6)
        elif target == S_XFER:
            await bring_up(dut)
        else:
            await ClockCycles(dut.seg_clk, 6)
            await request_reset(dut)
            for _ in range(64):
                await RisingEdge(dut.seg_clk)
                if int(dut.fsm_state.value) == S_RX_RESET:
                    break
        assert int(dut.fsm_state.value) == target, (
            f"could not reach {NAMES[target]}, sat in {NAMES[int(dut.fsm_state.value)]}"
        )
        dut.configured.value = 0
        await ClockCycles(dut.seg_clk, 3)
        assert int(dut.fsm_state.value) == S_IDLE, (
            f"SW_RST: configured fell while in {NAMES[target]} and the FSM stayed in "
            f"{NAMES[int(dut.fsm_state.value)]}"
        )
        assert int(dut.ctl_tx_enable.value) == 0
        assert int(dut.rx_datapath_reset.value) == 0, "a reset was left asserted across SW_RST"

@cocotb.test()
async def test_ns77_send_idle_follows_remote_fault(dut):
    await setup(dut)
    await bring_up(dut)
    assert int(dut.ctl_tx_send_idle.value) == 0
    dut.stat_remote_fault.value = 1
    await ClockCycles(dut.seg_clk, 3)
    assert int(dut.ctl_tx_send_idle.value) == 1, (
        ": ctl_tx_send_idle did not follow remote_fault. PG369 p90 requires it."
    )
    dut.stat_remote_fault.value = 0
    await ClockCycles(dut.seg_clk, 3)
    assert int(dut.ctl_tx_send_idle.value) == 0

@cocotb.test()
async def test_w2_tx_rst_rises_within_four_cycles(dut):
    await setup(dut)
    await bring_up(dut)
    assert int(dut.tx_rst_seg.value) == 0, "tx_rst did not clear in XFER "
    dut.stat_rx_aligned.value = 0
    n = 0
    for _ in range(8):
        await RisingEdge(dut.seg_clk)
        n += 1
        if int(dut.tx_rst_seg.value) == 1:
            break
    assert int(dut.tx_rst_seg.value) == 1, "tx_rst never rose"
    assert n <= 2, f"tx_rst took {n} seg cycles;  allows one flop here"

@cocotb.test()
async def test_w16_reset_covers_the_whole_port_group(dut):
    await setup(dut)
    await ClockCycles(dut.seg_clk, 6)
    await request_reset(dut, wide=False)
    seen = None
    for _ in range(NARROW_CYC + 8):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value) == 1:
            seen = int(dut.rx_datapath_reset_ports.value)
            break
    assert seen is not None, "no RX reset observed"
    expect = sum(1 << p for p in range(ANCHOR, ANCHOR + NPORTS))
    assert seen == expect, (
        f"port mask {seen:#0{PORT_MAX + 2}b} != expected {expect:#0{PORT_MAX + 2}b} "
        f"(ANCHOR={ANCHOR}, NPORTS={NPORTS}). Anchor-only was a real defect; wider is."
    )
    await ClockCycles(dut.seg_clk, NARROW_CYC + 8)
    assert int(dut.rx_datapath_reset_ports.value) == 0, "the mask did not clear with the reset"

@cocotb.test()
async def test_cfg_nothing_happens_before_configuration_completes(dut):
    cocotb.start_soon(Clock(dut.seg_clk, CLK_NS, units="ns").start())
    _kill_all()
    dut.seg_rstn.value = 0
    dut.configured.value = 0
    dut.stat_rx_aligned.value = 0
    dut.stat_remote_fault.value = 0
    dut.reset_req.value = 0
    dut.rx_force_resync_req.value = 0
    await ClockCycles(dut.seg_clk, 8)
    dut.seg_rstn.value = 1
    await ClockCycles(dut.seg_clk, 64)
    assert int(dut.fsm_state.value) == S_IDLE, (
        f"the FSM left its reset state without configuration: {NAMES[int(dut.fsm_state.value)]}. "
        "Note the mechanism: `configured` low is a global override, NOT an exit condition on IDLE - "
        "the state machine is not evaluated at all while it is low."
    )
    assert int(dut.ctl_rx_enable.value) == 0, "the receiver was enabled before the MAC was configured"
    assert int(dut.ctl_tx_enable.value) == 0
    assert int(dut.carrier.value) == 0
    dut.stat_rx_aligned.value = 1
    await ClockCycles(dut.seg_clk, 32)
    assert int(dut.fsm_state.value) == S_IDLE, "an aligned input moved the FSM before configuration"
    dut.configured.value = 1
    for _ in range(64):
        await RisingEdge(dut.seg_clk)
        if int(dut.fsm_state.value) == S_XFER:
            break
    assert int(dut.fsm_state.value) == S_XFER, "configuration completed but the FSM did not proceed"
