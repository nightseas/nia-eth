#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : test_dcmac_mac_dual.py
# Description : The MAC group tests: a receive reset request reaches only its own client,
#               a force resync is per client, a receive request never asserts a transmit
#               reset, and both groups reach link up.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..")))
from nia_sim_watchdog import wallclock_guard

CLK_NS = 4.0
N_CLIENT = int(os.environ.get("N_CLIENT", 2))
DATA_W = 512
KEEP_W = DATA_W // 8
PORT_MAX = int(os.environ.get("PORT_MAX", 6))
BRINGUP_US = float(os.environ.get("NIA_BRINGUP_US", 400))
TEST_US = float(os.environ.get("NIA_TEST_US", 600))
EN_DPRST_SYNC = int(os.environ.get("EN_DPRST_SYNC", 1))

FSM_XFER     = 3
FSM_RX_RESET = 4

GATE_STABLE_CYC = 8

ROUTE_GATED  = "gated"
ROUTE_DIRECT = "direct"

_WRITE_SHADOW = {}

def _shadow_key(sig):
    return str(getattr(sig, "_path", None) or sig._name)

def write_vec(sig, val):
    _WRITE_SHADOW[_shadow_key(sig)] = int(val)
    sig.value = int(val)

def _shadow_read(sig):
    key = _shadow_key(sig)
    if key not in _WRITE_SHADOW:
        _WRITE_SHADOW[key] = int(sig.value)
    return _WRITE_SHADOW[key]

def clear_write_shadow():
    _WRITE_SHADOW.clear()

def get_slice(sig, idx, width):
    return (int(sig.value) >> (idx * width)) & ((1 << width) - 1)

def set_slice(sig, idx, width, val):
    mask = ((1 << width) - 1) << (idx * width)
    write_vec(sig, (_shadow_read(sig) & ~mask) | ((val & ((1 << width) - 1)) << (idx * width)))

def bit(sig, idx):
    return (int(sig.value) >> idx) & 1

def set_bit(sig, idx, val):
    write_vec(sig, (_shadow_read(sig) & ~(1 << idx)) | ((val & 1) << idx))

class Counters:

    FIELDS = (("rx_err_frames", 32), ("rx_drop_frames", 32), ("mac_fsm_state", 3),
              ("rx_overflow", 1), ("rx_trunc", 1), ("tx_cpl_overflow", 1),
              ("link_up", 1), ("tx_status", 1), ("rx_status", 1),
              ("tx_rst", 1), ("rx_rst", 1))

    def __init__(self, dut, c):
        self.c = c
        self.v = {}
        for name, w in self.FIELDS:
            self.v[name] = get_slice(getattr(dut, name), c, w)

    def diff(self, other):
        return {k: (other.v[k], v) for k, v in self.v.items() if other.v[k] != v}

    def __repr__(self):
        return "c%d %s" % (self.c, self.v)

async def reset_and_bringup(dut, log):
    clear_write_shadow()
    dut.sys_reset.value = 1
    dut.gt_ref_clk1_p.value = 0
    dut.gt_ref_clk1_n.value = 1
    dut.gt_ref_clk0_n.value = 1
    dut.gt_rxp_in.value = 0
    dut.gt_rxn_in.value = 0
    dut.seg_ptp_time.value = 0
    write_vec(dut.s_axis_tx_tdata, 0)
    write_vec(dut.s_axis_tx_tkeep, 0)
    write_vec(dut.s_axis_tx_tvalid, 0)
    write_vec(dut.s_axis_tx_tlast, 0)
    write_vec(dut.s_axis_tx_tuser, 0)
    write_vec(dut.m_axis_tx_cpl_ready, (1 << N_CLIENT) - 1)
    write_vec(dut.ctl_rx_force_resync_req, 0)
    write_vec(dut.ctl_rx_datapath_reset_req, 0)
    write_vec(dut.ctl_tx_datapath_reset_req, 0)
    dut.ctl_bringup_restart_req.value = 0
    dut.ctl_stats_req.value = 0
    dut.ctl_stat_rd_idx.value = 0

    cocotb.start_soon(Clock(dut.gt_ref_clk0_p, CLK_NS, units="ns").start())
    for _ in range(32):
        await RisingEdge(dut.gt_ref_clk0_p)
    dut.sys_reset.value = 0

    limit = int(BRINGUP_US * 1000 / CLK_NS)
    want = (1 << N_CLIENT) - 1
    for i in range(limit):
        await RisingEdge(dut.gt_ref_clk0_p)
        if int(dut.link_up.value) == want:
            log.info(": BOTH groups reached link_up unattended after %d cycles "
                     "(%.1f us) from the ONE ROM sequencer", i, i * CLK_NS / 1000.0)
            for _ in range(64):
                await RisingEdge(dut.gt_ref_clk0_p)
            return
    raise AssertionError(
        " FAIL: link_up = 0b%s after %d cycles (%.0f us, the  bound). The ONE ROM must "
        "bring BOTH groups up unattended; one group coming up and the other not is the failure "
        "`test_ns20_both_groups_reach_link_up` exists to name."
        % (format(int(dut.link_up.value), "0%db" % N_CLIENT), limit, BRINGUP_US))

async def send_frame(dut, c, payload, log):
    beats = [payload[i:i + KEEP_W] for i in range(0, len(payload), KEEP_W)] or [b""]
    limit = int(TEST_US * 1000 / CLK_NS)
    for n, beat in enumerate(beats):
        last = (n == len(beats) - 1)
        word = int.from_bytes(beat.ljust(KEEP_W, b"\x00"), "little")
        keep = (1 << len(beat)) - 1
        set_slice(dut.s_axis_tx_tdata, c, DATA_W, word)
        set_slice(dut.s_axis_tx_tkeep, c, KEEP_W, keep)
        set_bit(dut.s_axis_tx_tlast, c, 1 if last else 0)
        set_bit(dut.s_axis_tx_tvalid, c, 1)
        taken = False
        for _ in range(limit):
            await ReadOnly()
            ready = bit(dut.s_axis_tx_tready, c)
            await RisingEdge(dut.gt_ref_clk0_p)
            if ready:
                taken = True
                break
        if not taken:
            set_bit(dut.s_axis_tx_tvalid, c, 0)
            set_bit(dut.s_axis_tx_tlast, c, 0)
            raise AssertionError(
                "TX STALL: client %d's beat %d of %d (%d byte(s), tlast=%d) was never accepted -- "
                "s_axis_tx_tready[%d] stayed low for %d clocks (%.0f us). Nothing downstream of "
                "this driver can be judged from a run in which the frame never entered the MAC."
                % (c, n, len(beats), len(beat), 1 if last else 0, c, limit, TEST_US))
    set_bit(dut.s_axis_tx_tvalid, c, 0)
    set_bit(dut.s_axis_tx_tlast, c, 0)

class RxCollector:

    def __init__(self, dut, c, budget, stop):
        self.dut = dut
        self.c = c
        self.budget = int(budget)
        self._stop = stop
        self.frames = []
        self.beats = 0
        self.max_hold = 0
        self.runaway = None

    async def run(self):
        cur = bytearray()
        hold = 0
        prev = b""
        while not self._stop:
            await RisingEdge(self.dut.gt_ref_clk0_p)
            if not bit(self.dut.m_axis_rx_tvalid, self.c):
                hold = 0
                continue
            self.beats += 1
            last = bit(self.dut.m_axis_rx_tlast, self.c)
            hold = hold + 1 if last else 0
            if hold > self.max_hold:
                self.max_hold = hold
            word = get_slice(self.dut.m_axis_rx_tdata, self.c, DATA_W)
            keep = get_slice(self.dut.m_axis_rx_tkeep, self.c, KEEP_W)
            nb = bin(keep).count("1")
            cur += word.to_bytes(KEEP_W, "little")[:nb]
            if last:
                frame = bytes(cur)
                cur = bytearray()
                self.frames.append(frame)
                if self.runaway is None and len(self.frames) > self.budget:
                    self.runaway = {
                        "at": len(self.frames), "beats": self.beats, "hold": self.max_hold,
                        "keep_popcount": nb, "payload": frame[:16].hex(),
                        "is_prev_tail": bool(prev) and prev.endswith(frame),
                        "single_byte": len(set(frame)) == 1 if frame else False,
                    }
                    self._stop.append(True)
                prev = frame

def runaway_report(col, n_sent, clause):
    r = col.runaway
    return (
        "%s FAIL -  RX RUNAWAY on client %d, not a byte mismatch: %d+ frames delivered against "
        "%d sent (stopped at the budget; the old collector would have kept going to ~1016).\n"
        "  longest run of consecutive clocks with tvalid & tlast BOTH high = %d\n"
        "  total RX beats seen = %d ; offending frame #%d: %d keep bytes, payload[0:16]=%s, "
        "single-repeated-byte=%s, equals-tail-of-previous-frame=%s\n"
        "  => `max_hold > 1` means the RX face is delimiting a ONE-BEAT FRAME PER CLOCK from stale "
        "data. `m_axis_rx` has no tready (it is tied 1'b1 in dcmac_axis_adapter.sv, ), so "
        "the RX CDC cannot self-stick: the beats were genuinely presented by the segmented RX "
        "client.\n"
        "   NOW READ THE LOG FOR `NIA_PHY_STUB VIOLATION`:\n"
        "      present  => the TX chain re-offered an already-accepted beat - a DUT-side "
        "AXIS/PG369 defect, and the stub is telling you the beat that did it.\n"
        "      ABSENT   => the loopback model is at fault, NOT the design "
        "(dcmac_phy_model.sv,: the RX sideband was captured unconditionally, "
        "so a stale asserted `eop` made every idle clock its own frame)."
        % (clause, col.c, r["at"], n_sent, r["hold"], r["beats"], r["at"],
           r["keep_popcount"], r["payload"], r["single_byte"], r["is_prev_tail"]))

def _guard(dut, name):
    def snap():
        return ["link_up=0b%s tx_rst=0b%s rx_rst=0b%s seq_state=%s seq_pc=%s"
                % (format(int(dut.link_up.value), "0%db" % N_CLIENT),
                   format(int(dut.tx_rst.value), "0%db" % N_CLIENT),
                   format(int(dut.rx_rst.value), "0%db" % N_CLIENT),
                   dut.ctl_seq_state.value, dut.ctl_seq_pc.value)]
    return wallclock_guard(name, snapshot=snap)

def mac_sig(dut, name):
    try:
        return getattr(dut, name)
    except AttributeError:
        raise AssertionError(
            "WITNESS UNAVAILABLE: the simulator does not expose `%s`, which is a wire of "
            "`dcmac_mac_group` itself. Either the net was optimised away (the build must keep "
            "the top module's nets public) or it was renamed in the RTL. This suite proves that a "
            "per-client request was ACCEPTED and PERFORMED by reading it, so without it every "
            "isolation result here would be unfalsifiable." % name)

def gate_terms(dut, c):
    return {
        "gt_dprst_done": int(mac_sig(dut, "gt_dprst_done").value),
        "gt_tx_done_all": int(mac_sig(dut, "gt_tx_done_all").value),
        "gt_rx_done_all": int(mac_sig(dut, "gt_rx_done_all").value),
        "seq_busy": int(dut.ctl_seq_busy.value),
        "stuck": bit(mac_sig(dut, "dprst_rx_stuck"), c),
        "refused": bit(mac_sig(dut, "dprst_rx_refused"), c),
        "refuse_cnt": get_slice(mac_sig(dut, "dprst_rx_cnt"), c, 4),
        "gate_state": get_slice(mac_sig(dut, "dprst_rx_state"), c, 2),
    }

def gate_terms_str(t):
    return ("gt_dprst_done=%d (gt_tx_done_all=0x%02X gt_rx_done_all=0x%02X) seq_busy=%d "
            "sts_stuck=%d sts_refused=%d sts_refuse_cnt=%d sts_state=%d"
            % (t["gt_dprst_done"], t["gt_tx_done_all"], t["gt_rx_done_all"], t["seq_busy"],
               t["stuck"], t["refused"], t["refuse_cnt"], t["gate_state"]))

async def wait_until_request_gate_accepts(dut, log, clause):
    limit = int(TEST_US * 1000 / CLK_NS)
    stable = 0
    for i in range(limit):
        await RisingEdge(dut.gt_ref_clk0_p)
        t = gate_terms(dut, 0)
        ok = (t["gt_dprst_done"] == 1 and t["seq_busy"] == 0
              and int(mac_sig(dut, "dprst_rx_stuck").value) == 0)
        stable = stable + 1 if ok else 0
        if stable >= GATE_STABLE_CYC:
            log.info("%s: the host request gate's interlock is satisfied after %d cycles -- %s",
                     clause, i, gate_terms_str(t))
            return i
    t = gate_terms(dut, 0)
    raise AssertionError(
        "%s FAIL (THE REQUEST GATE CAN NEVER ACCEPT) -- the interlock never held for %d "
        "consecutive clocks in %d cycles (%.0f us). Measured: %s.\n"
        "  A host RX datapath-reset request is therefore DROPPED at "
        "`dcmac_mac_group.sv` `g_dprst_gate`, unconditionally, and no per-client route to a "
        "reset exists from this module's boundary. The test refuses to raise a request it can "
        "prove will be thrown away, because a request that reaches nobody disturbs nobody and "
        "the isolation claim would then pass for the wrong reason.\n"
        "  If `gt_dprst_done` is 0 with both done words equal to 0x03, read "
        "`dcmac_mac_group.sv:695`: the term is written `(gt_tx_done_all == 8'hFF) && "
        "(gt_rx_done_all == 8'hFF)`, while 0x03 is this design's own reset-done expectation "
        "(`ctl/dcmac_ctl_pkg.sv:144`, used as the sequencer's compare at "
        "`ctl/dcmac_ctl_seq.sv:835`) and 0x03 is also the widest word either PHY can produce "
        "(`dcmac_phy_wrapper.sv:374-375` drives `{6'd0, {2{done}}}`, and the stub drives 8'h03). "
        "A comparison against 0x FF cannot be true in any configuration of this design."
        % (clause, GATE_STABLE_CYC, limit, TEST_US, gate_terms_str(t)))

class ArrivalWatch:

    def __init__(self, dut, victim, other):
        self.dut = dut
        self.victim = victim
        self.other = other
        self.stop = False
        self.seen = {
            "gated_pulse": 0,
            "link_reset_req": 0,
            "dp_reset": 0,
            "fsm_reset": 0,
            "rx_rst": 0,
            "link_dn": 0,
            "pin_victim": 0,
            "pin_other": 0,
        }

    def sample(self):
        s = self.seen
        v = self.victim
        d = self.dut
        s["gated_pulse"] |= bit(mac_sig(d, "host_rx_dp_req_gated"), v)
        s["link_reset_req"] |= bit(mac_sig(d, "link_reset_req"), v)
        s["dp_reset"] |= bit(mac_sig(d, "p_rx_dp_reset"), v)
        s["fsm_reset"] |= 1 if get_slice(d.mac_fsm_state, v, 3) == FSM_RX_RESET else 0
        s["rx_rst"] |= bit(d.rx_rst, v)
        s["link_dn"] |= 1 - bit(d.link_up, v)
        s["pin_victim"] |= bit(mac_sig(d, "p_ctl_rx_force_resync"), v)
        s["pin_other"] |= bit(mac_sig(d, "p_ctl_rx_force_resync"), self.other)

    async def run(self):
        while not self.stop:
            await RisingEdge(self.dut.gt_ref_clk0_p)
            self.sample()

    def __repr__(self):
        return " ".join("%s=%d" % (k, self.seen[k]) for k in sorted(self.seen))

async def _isolation_body(dut, victim_hurt, log, req_signal, clause, why, route=ROUTE_GATED):
    other = 1 - victim_hurt
    await reset_and_bringup(dut, log)

    stop = []
    rng = random.Random(0xB2 + victim_hurt)
    sent = [bytes(rng.randrange(256) for _ in range(64 + 8 * i)) for i in range(6)]
    col = RxCollector(dut, other, budget=len(sent), stop=stop)
    got = col.frames
    cocotb.start_soon(col.run())

    await send_frame(dut, other, sent[0], log)
    for _ in range(256):
        await RisingEdge(dut.gt_ref_clk0_p)
    assert got, ("the OTHER client (c%d) delivered NO frame before the event, so this test could "
                 "not distinguish 'undisturbed' from 'never worked'.  A vacuous isolation test is "
                 "how  came to be reported green while undefended (audit)." % other)

    before = Counters(dut, other)

    if route == ROUTE_GATED:
        await wait_until_request_gate_accepts(dut, log, clause)
        pre = gate_terms(dut, victim_hurt)
        assert pre["refused"] == 0 and pre["refuse_cnt"] == 0, (
            "%s FAIL (STATE BEFORE THE STIMULUS IS ALREADY DIRTY) -- client %d's request gate "
            "reports a dropped request before this test raised one: %s. `sts_refused` is sticky "
            "and nothing clears it in this composition, so a later 'accepted' verdict could not "
            "be trusted." % (clause, victim_hurt, gate_terms_str(pre)))

    log.info("%s: baseline c%d ok (%d frame(s)); now raising %s[%d] with the sequencer OUTSIDE "
             "group %d's ladder -  exactly the state  travelled on",
             clause, other, len(got), req_signal, victim_hurt, victim_hurt)

    watch = ArrivalWatch(dut, victim_hurt, other)
    cocotb.start_soon(watch.run())
    await RisingEdge(dut.gt_ref_clk0_p)
    set_bit(getattr(dut, req_signal), victim_hurt, 1)
    for i in range(1, len(sent)):
        await send_frame(dut, other, sent[i], log)
    for _ in range(512):
        await RisingEdge(dut.gt_ref_clk0_p)
    set_bit(getattr(dut, req_signal), victim_hurt, 0)
    for _ in range(512):
        await RisingEdge(dut.gt_ref_clk0_p)
    watch.stop = True
    stop.append(True)
    await RisingEdge(dut.gt_ref_clk0_p)

    after = Counters(dut, other)
    moved = after.diff(before)
    seen = watch.seen
    post = gate_terms(dut, victim_hurt)

    assert not moved, (
        "%s FAIL - `%s[%d]` DISTURBED CLIENT %d: %s.\n %s\nThis is the cross-client reset that on "
        "a wire presents as an INTERMITTENCY, the most expensive failure class this program has "
        "paid for (twice:  7/10 -> 20/20,  6/10 -> 15/15).\n  arrival observables: %s; "
        "gate: %s"
        % (clause, req_signal, victim_hurt, other, moved, why, watch, gate_terms_str(post)))

    assert col.runaway is None, runaway_report(col, len(sent), clause)
    assert got == sent, (
        "%s FAIL - client %d's frames are NOT byte-exact across a `%s[%d]` event: sent %d "
        "frame(s) %s, got %d %s (RX beats=%d, max tvalid&tlast hold=%d). A reset that reaches the "
        "wrong client drops that client's RX (`dcmac_phy_model.sv` `rx_kill`), which is what "
        "makes the leak observable here."
        % (clause, other, req_signal, victim_hurt, len(sent), [len(f) for f in sent],
           len(got), [len(f) for f in got], col.beats, col.max_hold))

    if route == ROUTE_GATED:
        assert seen["gated_pulse"] and post["refused"] == 0, (
            "%s FAIL (THE REQUEST WAS DROPPED, SO THIS RUN PROVES NOTHING) -- `%s[%d]` was held "
            "for 512+ cycles and the request gate never issued it: host_rx_dp_req_gated[%d] never "
            "asserted and the gate reports %s.\n  The gate accepts only on the rising edge of the "
            "level and only while its interlock holds, and it never queues. This test waited for "
            "that interlock before raising the level, so a refusal means the interlock stopped "
            "being satisfiable between the wait and the edge, or the route changed.\n  arrival "
            "observables: %s"
            % (clause, req_signal, victim_hurt, victim_hurt, gate_terms_str(post), watch))
        assert seen["dp_reset"] or seen["fsm_reset"], (
            "%s FAIL (ACCEPTED BUT NEVER PERFORMED) -- the gate issued its pulse for client %d, "
            "but that client's FSM never performed the reset: %s. The accepted pulse merges into "
            "that client's request upstream of the FSM, and the FSM is the only driver of reset "
            "pins, so a pulse with no reset means the merge or the FSM's accept edge is broken.\n"
            "  Note `link_reset_req` above is the SUPERVISOR's request only: the host term is "
            "merged in at the port instance and is not a signal, so 0 there is expected "
            "for a host request." % (clause, victim_hurt, watch))
        assert seen["rx_rst"] or seen["link_dn"], (
            "%s FAIL (PERFORMED BUT INVISIBLE AT THE BOUNDARY) -- client %d's reset ran without "
            "`rx_rst[%d]` asserting or `link_up[%d]` dropping: %s. Both are derived from the FSM "
            "leaving its transfer state, so this would mean the reset was performed without the "
            "port leaving transfer -- and then a sibling could not have been protected by it "
            "either." % (clause, victim_hurt, victim_hurt, victim_hurt, watch))
    else:
        assert seen["pin_victim"], (
            "%s FAIL (VACUOUS) -- `%s[%d]` was held for 512+ cycles and never reached client %d's "
            "own pin: p_ctl_rx_force_resync[%d] stayed low the whole time (%s). This request is a "
            "pass-through, so its pin IS the arrival witness; a request arriving nowhere cannot "
            "disturb a sibling and no isolation claim may be read off this run."
            % (clause, req_signal, victim_hurt, victim_hurt, victim_hurt, watch))
        assert not seen["pin_other"], (
            "%s FAIL -- `%s[%d]` also asserted client %d's pin: p_ctl_rx_force_resync[%d] went "
            "high (%s). That is the per-client claim failing at the pin itself, which is the "
            "shortest possible statement of the defect this test exists for."
            % (clause, req_signal, victim_hurt, other, other, watch))

    log.info("%s PASS: client %d byte-exact (%d frames), every counter/FSM/link observable unmoved, "
             "AND the request demonstrably landed on client %d only [%s ; gate: %s] across the "
             "whole `%s[%d]` event", clause, other, len(got), victim_hurt, watch,
             gate_terms_str(post), req_signal, victim_hurt)

@cocotb.test()
async def test_ns21_b2_rx_dp_req_c1_does_not_disturb_c0(dut):
    g = _guard(dut, "ns21_b2_c1_to_c0")
    try:
        await _isolation_body(
            dut, 1, dut._log, "ctl_rx_datapath_reset_req", "",
            " was `.rx_datapath_reset_req(|ctl_rx_datapath_reset_req)` at "
            "`dcmac_mac_group.sv:307` - both clients OR-reduced into the ONE sequencer, "
            "losing the client index; `dcmac_ctl_seq.sv:864` then masked with `port_group_mask`, "
            "which outside a ladder reads as GROUP 0's slots (`:538`).",
            route=ROUTE_GATED)
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns21_b2_rx_dp_req_c0_does_not_disturb_c1(dut):
    g = _guard(dut, "ns21_b2_c0_to_c1")
    try:
        await _isolation_body(
            dut, 0, dut._log, "ctl_rx_datapath_reset_req", "(mirrored)",
            "The symmetric half of, which the audit named explicitly and which a "
            "single-direction test would have missed.",
            route=ROUTE_GATED)
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns21_force_resync_req_is_per_client(dut):
    g = _guard(dut, "ns21_resync_isolation")
    try:
        await _isolation_body(
            dut, 1, dut._log, "ctl_rx_force_resync_req", "(resync)",
            "`rx_force_resync_req` was OR-reduced into the sequencer on the same line as 's "
            "RX request. It is a pass-through (`dcmac_ctl_seq.sv:871`, C17) so its blast radius is "
            "smaller -- which is exactly why it would have been the one nobody re-checked.",
            route=ROUTE_DIRECT)
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns22_rx_request_never_asserts_a_tx_reset(dut):
    g = _guard(dut, "ns22_rx_only")
    try:
        await reset_and_bringup(dut, dut._log)
        base = [Counters(dut, c) for c in range(N_CLIENT)]
        tx_dp_seen = 0
        phy_tx_dp_seen = 0
        accepted = 0
        for c in range(N_CLIENT):
            set_bit(dut.ctl_rx_datapath_reset_req, c, 1)
            for _ in range(400):
                await RisingEdge(dut.gt_ref_clk0_p)
                tx_dp_seen |= int(mac_sig(dut, "p_tx_dp_reset").value)
                phy_tx_dp_seen |= int(mac_sig(dut, "phy_tx_dp_reset").value)
                accepted |= int(mac_sig(dut, "host_rx_dp_req_gated").value)
            set_bit(dut.ctl_rx_datapath_reset_req, c, 0)
            for _ in range(400):
                await RisingEdge(dut.gt_ref_clk0_p)
                tx_dp_seen |= int(mac_sig(dut, "p_tx_dp_reset").value)
                phy_tx_dp_seen |= int(mac_sig(dut, "phy_tx_dp_reset").value)
                accepted |= int(mac_sig(dut, "host_rx_dp_req_gated").value)
        assert tx_dp_seen == 0 and phy_tx_dp_seen == 0, (
            " FAIL: an RX datapath-reset request asserted a TX DATAPATH RESET -- "
            "p_tx_dp_reset = 0b%s, phy_tx_dp_reset = 0b%s. The escalation is RX-ONLY. "
            "MEASURED: RX-only took cross-cage dual-200G from 6/10 to 15/15, "
            "and the vendor exdes defect was exactly one shared bit."
            % (format(tx_dp_seen, "0%db" % N_CLIENT),
               format(phy_tx_dp_seen, "0%db" % N_CLIENT)))
        for c in range(N_CLIENT):
            moved = Counters(dut, c).diff(base[c])
            moved.pop("rx_rst", None)
            moved.pop("rx_status", None)
            moved.pop("mac_fsm_state", None)
            if not accepted:
                assert "tx_rst" not in moved and "tx_status" not in moved, (
                    " FAIL: client %d's TX side moved although no request was ever accepted "
                    "by the gate: %s" % (c, moved))
        refused_all = int(mac_sig(dut, "dprst_rx_refused").value)
        terms = gate_terms(dut, 0)
        assert accepted or refused_all == (1 << N_CLIENT) - 1, (
            " INCONCLUSIVE: no request was accepted (host_rx_dp_req_gated never asserted) and "
            "the gate does not report having dropped one either -- sts_refused = 0b%s across %d "
            "clients, %s. One of the two must be true, or the request went somewhere this test "
            "cannot see."
            % (format(refused_all, "0%db" % N_CLIENT), N_CLIENT, gate_terms_str(terms)))
        dut._log.info(" PASS: no RX request on either client asserted a TX datapath reset "
                      "(p_tx_dp_reset and phy_tx_dp_reset both stayed 0). requests accepted by the "
                      "gate: 0b%s ; gate status: %s",
                      format(accepted, "0%db" % N_CLIENT), gate_terms_str(terms))
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns20_both_groups_reach_link_up(dut):
    g = _guard(dut, "ns20_both_groups")
    try:
        await reset_and_bringup(dut, dut._log)
        assert int(dut.link_up.value) == (1 << N_CLIENT) - 1
        assert int(dut.ctl_access_fault.value) == 0, (
            " FAIL: access_fault asserted - the ROM hit 0x0BAD_0BAD on the shared s_axi")
        dut._log.info(" PASS: link_up=0b%s, access_fault=0, retry_cnt=%s",
                      format(int(dut.link_up.value), "0%db" % N_CLIENT), dut.ctl_retry_cnt.value)
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns17_both_clients_concurrent_byte_exact(dut):
    g = _guard(dut, "ns17_concurrent")
    try:
        await reset_and_bringup(dut, dut._log)
        rng = random.Random(0x17)
        sent = {c: [bytes([0xC0 | c] * 4 + [rng.randrange(256)] * (60 + 4 * i))
                    for i in range(4)] for c in range(N_CLIENT)}
        stop = []
        cols = {c: RxCollector(dut, c, budget=len(sent[c]), stop=stop) for c in range(N_CLIENT)}
        got = {c: cols[c].frames for c in range(N_CLIENT)}
        for c in range(N_CLIENT):
            cocotb.start_soon(cols[c].run())
        for i in range(4):
            for c in range(N_CLIENT):
                await send_frame(dut, c, sent[c][i], dut._log)
        for _ in range(1024):
            if stop:
                break
            await RisingEdge(dut.gt_ref_clk0_p)
        stop.append(True)
        await RisingEdge(dut.gt_ref_clk0_p)
        for c in range(N_CLIENT):
            assert cols[c].runaway is None, runaway_report(cols[c], len(sent[c]), "")
        for c in range(N_CLIENT):
            assert got[c] == sent[c], (
                " FAIL: client %d not byte-exact under concurrent load. First bytes are "
                "client-tagged 0x%02X, so a swap reads as a WRONG TAG rather than as noise: "
                "sent %d %s, got %d %s (RX beats=%d, max tvalid&tlast hold=%d)"
                % (c, 0xC0 | c, len(sent[c]), [f[:4].hex() for f in sent[c]],
                   len(got[c]), [f[:4].hex() for f in got[c]], cols[c].beats, cols[c].max_hold))
        dut._log.info(" PASS: both clients byte-exact under concurrent load "
                      "(per client: %s frames, max tvalid&tlast hold=%s - a hold of 1 is normal, "
                      ">1 would be the runaway)",
                      [len(got[c]) for c in range(N_CLIENT)],
                      [cols[c].max_hold for c in range(N_CLIENT)])
    finally:
        if g:
            g.cancel()

@cocotb.test()
async def test_ns27_dprst_sync_is_timing_only_not_functional(dut):
    g = _guard(dut, "ns27_control")
    try:
        await reset_and_bringup(dut, dut._log)
        base = Counters(dut, 0)
        await wait_until_request_gate_accepts(dut, dut._log, "")
        watch = ArrivalWatch(dut, 1, 0)
        cocotb.start_soon(watch.run())
        await RisingEdge(dut.gt_ref_clk0_p)
        set_bit(dut.ctl_rx_datapath_reset_req, 1, 1)
        for _ in range(600):
            await RisingEdge(dut.gt_ref_clk0_p)
        set_bit(dut.ctl_rx_datapath_reset_req, 1, 0)
        for _ in range(600):
            await RisingEdge(dut.gt_ref_clk0_p)
        watch.stop = True
        await RisingEdge(dut.gt_ref_clk0_p)
        post = gate_terms(dut, 1)
        seen = watch.seen
        assert seen["gated_pulse"] and post["refused"] == 0, (
            " FAIL (EN_DPRST_SYNC=%d) -- the request was DROPPED by the request gate, so this "
            "run cannot say anything about the synchroniser: host_rx_dp_req_gated[1] never "
            "asserted and the gate reports %s. Observables: %s"
            % (EN_DPRST_SYNC, gate_terms_str(post), watch))
        assert seen["dp_reset"] or seen["fsm_reset"], (
            " FAIL (EN_DPRST_SYNC=%d): the requested reset never ARRIVED at client 1 -- the "
            "gate accepted it (%s) but the FSM never performed it (%s). The synchroniser must "
            "change timing, not function; swallowing the request is a functional change to a "
            "silicon-proven path." % (EN_DPRST_SYNC, gate_terms_str(post), watch))
        moved = Counters(dut, 0).diff(base)
        assert not moved, (
            "/ FAIL (EN_DPRST_SYNC=%d): client 0 moved: %s. Whether or not the crossing "
            "is synchronised, the reset must stay on its own client." % (EN_DPRST_SYNC, moved))
        dut._log.info(" control PASS at EN_DPRST_SYNC=%d: the request was accepted by the "
                      "gate and the reset arrived at its own client and only there [%s]. Compare "
                      "variant against the other; identical results are the claim, and neither variant can "
                      "see metastability.", EN_DPRST_SYNC, watch)
    finally:
        if g:
            g.cancel()
