# ---------------------------------------------------------------------------
# File        : test_dcmac_link_ctl.py
# Description : The control plane tests: bring-up completes and hands over, a group in
#               escalation does not freeze its sibling, the sibling keeps being polled,
#               recovery after an arbitrarily long outage, and the runtime register
#               setting the watchdog period.
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

N_GROUP = int(os.environ.get("N_GROUP", "2"))
NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
ANCHOR_1 = int(os.environ.get("ANCHOR_1", "1"))
CYC_PER_MS = int(os.environ.get("CYC_PER_MS", "20"))
LINK_WDT_MS = int(os.environ.get("LINK_WDT_MS", "20"))
LINK_CONFIRM_N = int(os.environ.get("LINK_CONFIRM_N", "2"))
ESC_MAX_STAGE = int(os.environ.get("ESC_MAX_STAGE", "3"))
T_RXDP_MS = int(os.environ.get("T_RXDP_MS", "5"))
DONE_MASK = int(os.environ.get("DONE_MASK", "3"))

PORT_SHIFT = 12
O_RX_PHY_STATUS = 0x00C00
O_RX_PHY_RT_STATUS = 0x00C04
ALIGN_MASK = 0x5
BAD_MAGIC = 0x0BAD_0BAD

T_SAMPLE_MS = int(os.environ.get("T_SAMPLE_MS", "2"))

WDT_CYC = LINK_WDT_MS * CYC_PER_MS

STAGE3 = ESC_MAX_STAGE >= 3
BRINGUP_CYC = 250_000

def anchor_of(g):
    return ANCHOR if g == 0 else ANCHOR_1

def poll_addr(g):
    return (O_RX_PHY_RT_STATUS + ((anchor_of(g) + 1) << PORT_SHIFT)) & 0xFFFFF


def latched_addr(g):
    return (O_RX_PHY_STATUS + ((anchor_of(g) + 1) << PORT_SHIFT)) & 0xFFFFF

class DcmacModel:

    def __init__(self, dut):
        self.dut = dut
        self.aligned = {g: True for g in range(N_GROUP)}
        self.reads = []
        self.writes = []
        self.cycle = 0
        self._addr_map = {}
        for g in range(N_GROUP):
            self._addr_map[poll_addr(g)] = g
            self._addr_map[latched_addr(g)] = g

    def rdata_for(self, addr):
        g = self._addr_map.get(addr & 0xFFFFF)
        if g is None:
            return 0x0000_0200
        return ALIGN_MASK if self.aligned[g] else 0x0000_0200

    def polls_of(self, g):
        a = poll_addr(g)
        return [c for (ad, c) in self.reads if ad == a]

    async def run(self):
        d = self.dut
        d.m_axil_awready.value = 1
        d.m_axil_wready.value = 1
        d.m_axil_arready.value = 1
        d.m_axil_bvalid.value = 0
        d.m_axil_bresp.value = 0
        d.m_axil_rvalid.value = 0
        d.m_axil_rresp.value = 0
        d.m_axil_rdata.value = 0

        aw = None
        wd = None
        pending_r = None
        bvalid = False
        rvalid = False

        while True:
            await RisingEdge(d.aclk)
            self.cycle += 1

            if bvalid and int(d.m_axil_bready.value):
                bvalid = False
            if rvalid and int(d.m_axil_rready.value):
                rvalid = False

            if int(d.m_axil_awvalid.value):
                aw = int(d.m_axil_awaddr.value) & 0xFFFFF
            if int(d.m_axil_wvalid.value):
                wd = int(d.m_axil_wdata.value)
            if int(d.m_axil_arvalid.value) and pending_r is None:
                pending_r = int(d.m_axil_araddr.value) & 0xFFFFF

            if aw is not None and wd is not None and not bvalid:
                self.writes.append((aw, wd))
                aw = None
                wd = None
                bvalid = True

            if pending_r is not None and not rvalid:
                self.reads.append((pending_r, self.cycle))
                d.m_axil_rdata.value = self.rdata_for(pending_r)
                pending_r = None
                rvalid = True

            d.m_axil_bvalid.value = 1 if bvalid else 0
            d.m_axil_rvalid.value = 1 if rvalid else 0

async def _start(dut, aligned=True):
    cocotb.start_soon(Clock(dut.aclk, 4, units="ns").start())
    cocotb.start_soon(Clock(dut.seg_clk, 3, units="ns").start())
    dut.aresetn.value = 0
    dut.seg_rstn.value = 0
    dut.host_link_reset_req.value = 0
    dut.host_rx_force_resync_req.value = 0
    dut.gt_tx_reset_done.value = 0
    dut.gt_rx_reset_done.value = 0
    dut.bringup_restart_req.value = 0
    dut.stats_req.value = 0
    dut.rx_force_resync_req.value = 0
    dut.rx_datapath_reset_req.value = 0
    dut.tx_datapath_reset_req.value = 0
    dut.stat_rd_idx.value = 0
    dut.link_wdt_ms.value = 0
    dut.m_axil_awready.value = 0
    dut.m_axil_wready.value = 0
    dut.m_axil_arready.value = 0
    dut.m_axil_bvalid.value = 0
    dut.m_axil_rvalid.value = 0
    dut.m_axil_rdata.value = 0
    dut.m_axil_bresp.value = 0
    dut.m_axil_rresp.value = 0
    await ClockCycles(dut.aclk, 10)
    dut.aresetn.value = 1
    dut.seg_rstn.value = (1 << N_GROUP) - 1
    dut.gt_tx_reset_done.value = DONE_MASK
    dut.gt_rx_reset_done.value = DONE_MASK
    model = DcmacModel(dut)
    for g in range(N_GROUP):
        model.aligned[g] = aligned
    cocotb.start_soon(model.run())
    await ClockCycles(dut.aclk, 4)
    return model

async def _wait_bringup(dut, limit=400_000):
    for _ in range(limit):
        await RisingEdge(dut.aclk)
        if int(dut.bringup_done.value):
            return True
    return False

S_IDLE = 0
S_XFER = 3


def _bus_probe(dut):
    def value(name):
        try:
            return int(getattr(dut, name).value)
        except Exception:
            return -1
    return (f" [rq_valid={value('rq_valid'):#x} rq_gnt={value('rq_gnt'):#x} "
            f"rq_ack={value('rq_ack'):#x} seq_busy={value('seq_busy')} "
            f"seq_state={value('seq_state')} bringup_done={value('bringup_done')} "
            f"rx_pcs_aligned={value('rx_pcs_aligned'):#x} link_up={value('link_up'):#x} "
            f"fsm_state={value('mac_fsm_state'):#o} sup_esc={value('sup_esc_count'):#x}]")

def _bit(sig, i):
    return (int(sig.value) >> i) & 1

@cocotb.test()
async def test_bringup_completes_and_hands_over(dut):
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted, so the handover never happened"
    dut._log.info("NIA_CTL bringup_done at cycle=%d writes=%d reads=%d",
                  model.cycle, len(model.writes), len(model.reads))
    await ClockCycles(dut.aclk, WDT_CYC * 3)
    for g in range(N_GROUP):
        assert _bit(dut.link_up, g) == 1, \
            f"group {g} is not up after the handover (link_up={int(dut.link_up.value):#x})" + _bus_probe(dut)
        assert _bit(dut.rx_pcs_aligned, g) == 1, f"group {g}'s live view is not up"
        assert len(model.polls_of(g)) >= 1, \
            f"group {g} was never polled by its supervisor - the handover did not reach it"
    assert int(dut.sup_esc_count.value) == 0, "a healthy link produced an escalation"

@cocotb.test()
async def test_ns56_a_group_in_escalation_does_not_freeze_its_sibling(dut):
    if N_GROUP < 2:
        dut._log.info("NIA_NS56 skip N_GROUP=%d - this property needs two groups", N_GROUP)
        return
    if STAGE3:
        dut._log.info("NIA_NS56 skip ESC_MAX_STAGE=%d - stage 3 re-runs the SHARED bring-up, so a "
                      "sibling IS disturbed by design (plan decision D2). This property is checked "
                      "on the `rxonly` and `stage2` variants, and D2 itself is asserted by "
                      "test_d2_stage3_restarts_the_shared_bringup.", ESC_MAX_STAGE)
        return
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted"
    await ClockCycles(dut.aclk, WDT_CYC * 2)
    assert _bit(dut.link_up, 1) == 1, "group 1 did not come up, so this test cannot run"

    model.aligned[0] = False
    await ClockCycles(dut.aclk, WDT_CYC * (LINK_CONFIRM_N + 3))
    assert int(dut.sup_esc_count.value) & 0xFFFF, "group 0 never escalated"
    assert _bit(dut.link_up, 1) == 1, "group 1 fell for group 0's fault - that is  inverted"

    n0 = len(model.polls_of(1))
    model.aligned[1] = False
    budget = WDT_CYC * (LINK_CONFIRM_N + 2) + T_RXDP_MS * CYC_PER_MS * 4
    fell_live = fell_up = None
    for c in range(budget):
        await RisingEdge(dut.aclk)
        if fell_live is None and _bit(dut.rx_pcs_aligned, 1) == 0:
            fell_live = c
        if fell_up is None and _bit(dut.link_up, 1) == 0:
            fell_up = c
        if fell_up is not None:
            break
    polls = len(model.polls_of(1)) - n0
    dut._log.info("NIA_NS56 group1_live_fell=%s group1_up_fell=%s polls=%d budget=%d",
                  fell_live, fell_up, polls, budget)
    assert fell_live is not None, \
        (f" VIOLATED: group 1's LIVE view never fell within {budget} cycles after its own "
         f"responder went unaligned, while group 0 was escalating. Group 1 was polled {polls} times.")
    assert fell_up is not None, \
        (f" VIOLATED: group 1's published `link_up` never fell within {budget} cycles "
         f"(one window + {LINK_CONFIRM_N} confirms). Group 1 was polled {polls} times.")

@cocotb.test()
async def test_ns57_the_sibling_keeps_being_polled(dut):
    if N_GROUP < 2:
        dut._log.info("NIA_NS57 skip N_GROUP=%d", N_GROUP)
        return
    if STAGE3:
        dut._log.info("NIA_NS57 skip ESC_MAX_STAGE=%d - once stage 3 restarts bring-up the bus "
                      "belongs to bring-up and the supervisors are disabled, which is D2 rather "
                      "than starvation. Checked on `rxonly` and `stage2`.", ESC_MAX_STAGE)
        return
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted"
    model.aligned[0] = False
    await ClockCycles(dut.aclk, WDT_CYC * 2)
    base = len(model.polls_of(1))
    await ClockCycles(dut.aclk, WDT_CYC * 6)
    got = model.polls_of(1)[base:]
    dut._log.info("NIA_NS57 group1_polls_while_group0_escalates=%d", len(got))
    assert len(got) >= 3, \
        f" VIOLATED: group 1 was polled only {len(got)} times in six windows while group 0 escalated"
    gaps = [b - a for a, b in zip(got, got[1:])]
    limit = WDT_CYC + 200
    assert all(g <= limit for g in gaps), \
        f" VIOLATED: a gap between group 1's polls was {max(gaps)} cycles, above one window + one transaction ({limit})"

@cocotb.test()
async def test_ns55_recovery_after_an_arbitrarily_long_outage(dut):
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted"
    model.aligned[0] = False
    if N_GROUP > 1:
        model.aligned[1] = False
    await ClockCycles(dut.aclk, WDT_CYC * 12 + (BRINGUP_CYC if STAGE3 else 0))
    esc = int(dut.sup_esc_count.value) & 0xFFFF
    least = 1 if STAGE3 else 3
    assert esc >= least, \
        (f"only {esc} escalations over twelve windows - the supervisor gave up "
         f"(ESC_MAX_STAGE={ESC_MAX_STAGE}, so at least {least} was required)")
    assert _bit(dut.link_up, 0) == 0, "the link is reported up while its responder is unaligned"
    assert int(dut.bringup_restart_req.value) == 0, \
        "this test wrote a host request, which would invalidate the criterion it is testing"

    for g in range(N_GROUP):
        model.aligned[g] = True
    ok = None
    for c in range(WDT_CYC * 8 + T_RXDP_MS * CYC_PER_MS * 8 + (BRINGUP_CYC if STAGE3 else 0)):
        await RisingEdge(dut.aclk)
        if all(_bit(dut.link_up, g) == 1 for g in range(N_GROUP)):
            ok = c
            break
    dut._log.info("NIA_NS55 recovered_after=%s cycles escalations=%d", ok, esc)
    assert ok is not None, \
        " VIOLATED: the link came back and the supervisor never published it - a state a program entered and only a human can leave" + _bus_probe(dut)

@cocotb.test()
async def test_ns59_the_window_register_sets_the_period(dut):
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted"

    long_ms = LINK_WDT_MS * 3
    val = 0
    for g in range(N_GROUP):
        val |= (long_ms if g == 0 else LINK_WDT_MS) << (16 * g)
    dut.link_wdt_ms.value = val
    await ClockCycles(dut.aclk, WDT_CYC * 2)

    base0 = len(model.polls_of(0))
    span = long_ms * CYC_PER_MS * 6
    await ClockCycles(dut.aclk, span)
    got0 = model.polls_of(0)[base0:]
    gaps = [b - a for a, b in zip(got0, got0[1:])]
    dut._log.info("NIA_NS59 window=%d ms gaps=%s", long_ms, gaps[:6])
    assert gaps, "group 0 was polled at most once in six of its own windows" + _bus_probe(dut)
    sample_cyc = T_SAMPLE_MS * CYC_PER_MS
    lo = sample_cyc * 0.5
    hi = sample_cyc * 2.0 + 200
    assert all(lo <= g <= hi for g in gaps), (
        f" VIOLATED: the poll period is set by T_SAMPLE_MS={T_SAMPLE_MS} ms, so the gaps must be "
        f"about {sample_cyc} cycles. They were {gaps[:8]}")

    mean_gap = sum(gaps) / len(gaps)
    per_window_0 = (long_ms * CYC_PER_MS) / mean_gap
    per_window_1 = (LINK_WDT_MS * CYC_PER_MS) / mean_gap
    dut._log.info("NIA_NS59 mean_gap=%.1f polls_per_window g0=%.1f g1=%.1f", mean_gap,
                  per_window_0, per_window_1)
    assert per_window_1 >= 2, (
        f" VIOLATED: only {per_window_1:.1f} poll(s) fall in a {LINK_WDT_MS} ms window, so the "
        f"window can expire with no sample in it")
    assert per_window_0 >= 2.5 * per_window_1, (
        f" VIOLATED: group 0's window is {long_ms} ms against group 1's {LINK_WDT_MS} ms, so it must "
        f"admit about three times as many polls. It admitted {per_window_0:.1f} against "
        f"{per_window_1:.1f}")

@cocotb.test()
async def test_ns61_the_rise_publishes_on_the_first_aligned_poll(dut):
    model = await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up never halted"
    model.aligned[0] = False
    fell = False
    for _ in range(WDT_CYC * (LINK_CONFIRM_N + 4)):
        await RisingEdge(dut.aclk)
        if _bit(dut.link_up, 0) == 0:
            fell = True
            break
    assert fell, "the link never fell, so the rise cannot be measured"

    model.aligned[0] = True
    n_before = len(model.polls_of(0))
    rose_after_polls = None
    for _ in range(WDT_CYC * 6 + T_RXDP_MS * CYC_PER_MS * 6 + (BRINGUP_CYC if STAGE3 else 0)):
        await RisingEdge(dut.aclk)
        if _bit(dut.link_up, 0) == 1:
            rose_after_polls = len(model.polls_of(0)) - n_before
            break
    dut._log.info("NIA_NS61 rose_after_polls=%s", rose_after_polls)
    assert rose_after_polls is not None, "the link came back and was never published" + _bus_probe(dut)
    assert rose_after_polls <= 2, \
        (f" VIOLATED: the rise took {rose_after_polls} aligned polls to publish; it must publish "
         f"on the first resolved ALIGNED poll (one extra is the poll already in flight)")

async def _wait_state(dut, group, want, limit=400_000):
    for _ in range(limit):
        await RisingEdge(dut.seg_clk)
        if ((int(dut.mac_fsm_state.value) >> (3 * group)) & 0x7) == want:
            return True
    return False


@cocotb.test()
async def test_the_state_machine_lives_in_the_control_block(dut):
    await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up did not complete"
    for g in range(N_GROUP):
        assert await _wait_state(dut, g, S_XFER), \
            f"group {g} did not reach the transfer state, fsm_state={int(dut.mac_fsm_state.value):#o}" + _bus_probe(dut)
        assert _bit(dut.link_up, g), f"group {g} does not publish link_up in the transfer state"
        await ClockCycles(dut.seg_clk, 2)
        assert _bit(dut.carrier, g), f"group {g} does not publish carrier in the transfer state"
        assert _bit(dut.ctl_tx_enable, g), f"group {g} does not enable the transmitter"


@cocotb.test()
async def test_configured_falling_returns_every_state_machine_to_idle(dut):
    await _start(dut, aligned=True)
    assert await _wait_bringup(dut), "bring-up did not complete"
    for g in range(N_GROUP):
        assert await _wait_state(dut, g, S_XFER), f"group {g} did not reach the transfer state" + _bus_probe(dut)
    dut.bringup_restart_req.value = 1
    await ClockCycles(dut.aclk, 4)
    dut.bringup_restart_req.value = 0
    for g in range(N_GROUP):
        assert await _wait_state(dut, g, S_IDLE, limit=200_000), \
            f"group {g} did not return to idle when configured fell, which the 2026-08-08 ruling requires"
        assert not _bit(dut.link_up, g), f"group {g} still publishes link_up with configuration down"
