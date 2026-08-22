# ---------------------------------------------------------------------------
# File        : test_dcmac_axis_adapter.py
# Description : The adapter tests: receive byte exactness including a packed beat, a start
#               of frame that arrives with a partial assembly reported rather than
#               delivered, and transmit byte exactness.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random
import logging

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, with_timeout

from cocotbext.axi import (AxiStreamBus, AxiStreamSource, AxiStreamMonitor,
                           AxiStreamFrame)

import sys
sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..")))
from seg_bfm import SegmentedSource, SegmentedSink

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
NPORTS = int(os.environ.get("NPORTS", "1"))
ANCHOR = int(os.environ.get("ANCHOR", "0"))
PTP_TS_EN = int(os.environ.get("PTP_TS_EN", "0"))
PTP_TS_W = int(os.environ.get("PTP_TS_W", "80"))
TX_TAG_W = int(os.environ.get("TX_TAG_W", "0"))

RX_USER_W = (PTP_TS_W + 1) if PTP_TS_EN else 1
TX_USER_W = TX_TAG_W + 1
TX_CPL_EN = bool(PTP_TS_EN) or TX_TAG_W > 0

DATA_W = int(os.environ.get("DATA_W", str(2 * N_SEG * SEG_W)))
BYTE_LANES = DATA_W // 8

TX_MHZ = float(os.environ.get("TX_MHZ", "250"))
RX_MHZ = float(os.environ.get("RX_MHZ", "250"))
SEG_PERIOD_NS = 2.56

def _period(mhz):
    return round(1000.0 / mhz * 500) / 500

TX_PERIOD_NS = _period(TX_MHZ)
RX_PERIOD_NS = _period(RX_MHZ)

S_IDLE, S_GT_LOCKED, S_WAIT_ALIGN, S_XFER, S_RX_RESET = 0, 1, 2, 3, 4

SEG_CYC_PER_MS = int(os.environ.get("SEG_CYC_PER_MS", "20"))
T_RXDP_MS = int(os.environ.get("T_RXDP_MS", "3"))
T_SERDES_MS = int(os.environ.get("T_SERDES_MS", "2"))
RXDP_CYC = SEG_CYC_PER_MS * T_RXDP_MS
SERDES_CYC = SEG_CYC_PER_MS * T_SERDES_MS
RESET_CYC = RXDP_CYC + SERDES_CYC + 16

EDGE_SIZES = [1, 2, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
              511, 512, 513, 1500, 1518]

def _rand_frame(n):
    return bytes(random.randint(0, 255) for _ in range(n))

_CLKS = {}
_BG = []

def _bg(coro):
    t = cocotb.start_soon(coro)
    _BG.append(t)
    return t

def _start_clocks(dut, rx_mhz=None):
    for t in list(_CLKS.values()) + _BG:
        try:
            t.kill()
        except Exception:
            pass
    _CLKS.clear()
    del _BG[:]
    _CLKS["seg"] = cocotb.start_soon(
        Clock(dut.seg_clk, SEG_PERIOD_NS, units="ns").start())
    _CLKS["tx"] = cocotb.start_soon(
        Clock(dut.tx_clk, TX_PERIOD_NS, units="ns").start())
    _CLKS["rx"] = cocotb.start_soon(
        Clock(dut.rx_clk, RX_PERIOD_NS if rx_mhz is None else _period(rx_mhz),
              units="ns").start())

async def _reset(dut, aligned=0, configured=1):
    dut.seg_rstn.value = 0
    dut.tx_rstn.value = 0
    dut.rx_rstn.value = 0
    dut.stat_rx_aligned.value = aligned
    dut.configured.value = configured
    dut.stat_remote_fault.value = 0
    dut.link_reset_req.value = 0
    dut.rx_force_resync_req.value = 0
    dut.tx_seg_ready.value = 1
    dut.seg_ptp_time.value = 0
    dut.m_axis_tx_cpl_ready.value = 1
    dut.s_axis_tx_tdata.value = 0
    dut.s_axis_tx_tkeep.value = 0
    dut.s_axis_tx_tvalid.value = 0
    dut.s_axis_tx_tlast.value = 0
    dut.s_axis_tx_tuser.value = 0
    dut.rx_seg_valid.value = 0
    dut.rx_seg_dat.value = 0
    dut.rx_seg_ena.value = 0
    dut.rx_seg_sop.value = 0
    dut.rx_seg_eop.value = 0
    dut.rx_seg_err.value = 0
    dut.rx_seg_mty.value = 0
    await ClockCycles(dut.seg_clk, 8)
    await ClockCycles(dut.tx_clk, 8)
    await ClockCycles(dut.rx_clk, 8)
    dut.seg_rstn.value = 1
    dut.tx_rstn.value = 1
    dut.rx_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)

async def _bringup(dut):
    dut.stat_rx_aligned.value = 1
    for _ in range(200):
        await RisingEdge(dut.seg_clk)
        if int(dut.ctl_tx_enable.value) == 1:
            break
    assert int(dut.ctl_tx_enable.value) == 1, \
        f"FSM never reached XFER: state={int(dut.fsm_state.value)}"
    await ClockCycles(dut.tx_clk, 8)
    await ClockCycles(dut.rx_clk, 8)

def _rx_monitor(dut):
    mon = AxiStreamMonitor(AxiStreamBus.from_prefix(dut, "m_axis_rx"), dut.rx_clk,
                           dut.rx_rstn, reset_active_level=False)
    mon.log.setLevel(logging.WARNING)
    return mon

def _tx_source(dut):
    src = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_axis_tx"), dut.tx_clk,
                          dut.tx_rstn, reset_active_level=False)
    src.log.setLevel(logging.WARNING)
    return src

def _rx_frame(fr):
    data = bytes(b for b, k in zip(fr.tdata, fr.tkeep) if k) if fr.tkeep is not None \
        else bytes(fr.tdata)
    tu = fr.tuser
    if tu is None:
        return data, 0, 0, 0
    if isinstance(tu, int):
        tu = [tu] * len(fr.tdata)
    last = tu[-1]
    earlier = tu[:-BYTE_LANES] if len(tu) > BYTE_LANES else []
    return data, last & 1, last >> 1, (1 if any(v & 1 for v in earlier) else 0)

def _drain(mon):
    out = []
    while not mon.empty():
        out.append(_rx_frame(mon.recv_nowait(compact=False)))
    return out

def _tx_tuser(nbytes, tag=0, abort_beat=None):
    base = (tag << 1) & ((1 << TX_USER_W) - 1)
    tu = [base] * nbytes
    if abort_beat is not None:
        b = abort_beat if abort_beat >= 0 else 0
        tu[min((b + 1) * BYTE_LANES - 1, nbytes - 1)] |= 1
    return tu

@cocotb.test()
async def test_rx_byte_exact(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    sizes = EDGE_SIZES + [random.randint(1, 1518) for _ in range(40)]
    frames = [_rand_frame(n) for n in sizes]

    for f in frames:
        await src.send(f)
        await src.idle_cycles(random.randint(1, 4))

    await ClockCycles(dut.rx_clk, 400)
    got = _drain(mon)

    assert int(dut.rx_overflow.value) == 0, " rx_overflow raised on a healthy path"
    assert len(got) == len(frames), (
        f": RX frame count {len(got)} != {len(frames)}; "
        f"sent={[len(f) for f in frames][:12]}... got={[len(g[0]) for g in got][:12]}...")
    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act[0], (f" RX frame {i} (len exp {len(exp)} / act {len(act[0])}) "
                               f"mismatch\n  exp={exp.hex()}\n  act={act[0].hex()}")
        assert act[1] == 0, f": frame {i} flagged bad on a clean link"
    dut._log.info(f"/ RX byte-exact PASS over {len(frames)} frames "
                  f"(seg {1000/SEG_PERIOD_NS:.3f} -> rx {1000/RX_PERIOD_NS:.3f} MHz)")

@cocotb.test()
async def test_rx_packed_beat_injected(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    seg_b = SEG_W // 8
    frame_a = bytes((0xA0 + (i & 0x0F)) for i in range(4 * seg_b + 1))
    frame_b = bytes((0xB0 + (i & 0x0F)) for i in range(4 * seg_b))

    await src.send_packed([frame_a, frame_b])
    await ClockCycles(dut.rx_clk, 400)
    got = _drain(mon)

    assert len(got) == 2, (
        f": a beat carrying an eop in segment 0 and a sop in segment 1 produced "
        f"{len(got)} frames, not 2; lengths {[len(g[0]) for g in got]}")
    assert got[0][0] == frame_a, (
        f": the ending frame is not byte exact\n  exp={frame_a.hex()}\n  act={got[0][0].hex()}")
    assert got[1][0] == frame_b, (
        f": the frame started in segment 1 is not byte exact\n  exp={frame_b.hex()}\n  act={got[1][0].hex()}")
    assert int(dut.rx_overflow.value) == 0, ": rx_overflow raised on a healthy packed stream"
    dut._log.info("/ injected packed beat PASS: two frames out, both byte exact")


@cocotb.test()
async def test_rx_packed_byte_exact(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    beat_b = N_SEG * SEG_W // 8
    tails = [64 + t for t in range(2 * beat_b)]
    hw_lengths = [65, 80, 97, 104, 112, 144, 1500, 1518]
    sizes = tails + hw_lengths
    frames = [_rand_frame(n) for n in sizes]

    await src.send_packed(frames)
    await ClockCycles(dut.rx_clk, 4000)
    got = _drain(mon)

    assert len(got) == len(frames), (
        f": packed stream produced {len(got)} frames, not {len(frames)}; "
        f"sent={sizes[:12]}... got={[len(g[0]) for g in got][:12]}...")
    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act[0], (
            f": packed frame {i} of {len(exp)} bytes (mod {beat_b} = {len(exp) % beat_b}) "
            f"mismatch, got {len(act[0])} bytes\n  exp={exp.hex()}\n  act={act[0].hex()}")
        assert act[1] == 0, f": packed frame {i} flagged bad on a clean link"
    assert int(dut.rx_overflow.value) == 0, ": rx_overflow raised on a healthy packed stream"
    dut._log.info(f"/ packed byte-exact PASS over {len(frames)} frames, "
                  f"every tail modulo {beat_b}")


@cocotb.test()
async def test_rx_sop_with_partial_assembly_is_reported(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    _rx_monitor(dut)
    await src.idle_cycles(8)

    seg_b = SEG_W // 8
    full_beat = int.from_bytes(bytes([0x5A] * (N_SEG * seg_b)), "little")
    one_seg = int.from_bytes(bytes([0x6B] * seg_b), "little")

    await src.send_beat(full_beat, ena=(1 << N_SEG) - 1, sop=0b1, eop=0)
    await src.send_beat(one_seg, ena=0b1, sop=0, eop=0)
    assert int(dut.rx_overflow.value) == 0, ": rx_overflow raised before the illegal beat"

    await src.send_beat(full_beat, ena=(1 << N_SEG) - 1, sop=0b1,
                        eop=(1 << (N_SEG - 1)))
    await ClockCycles(dut.seg_clk, 8)

    assert int(dut.rx_overflow.value) == 1, (
        ": a start of frame arriving with a partial assembly, which PG369 p127 does not permit, "
        "was absorbed without being reported")
    dut._log.info("/ a start of frame with a partial assembly is reported in rx_overflow")


@cocotb.test()
async def test_tx_byte_exact(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    sizes = EDGE_SIZES + [random.randint(1, 1518) for _ in range(40)]
    frames = [_rand_frame(n) for n in sizes]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f))))
        await source.wait()
    _bg(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 200, "us")
        got.append((data, err))

    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act[0], (f" TX frame {i} (len exp {len(exp)} / act {len(act[0])}) "
                               f"mismatch\n  exp={exp.hex()}\n  act={act[0].hex()}")
        assert act[1] == 0, f": TX frame {i} carried tx_seg_err without an abort"
    dut._log.info(f"/ TX byte-exact PASS over {len(frames)} frames "
                  f"(tx {1000/TX_PERIOD_NS:.3f} -> seg {1000/SEG_PERIOD_NS:.3f} MHz)")

@cocotb.test()
async def test_tx_backpressure(dut):
    _start_clocks(dut)
    await _reset(dut)
    await _bringup(dut)

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    async def backpressure():
        while True:
            dut.tx_seg_ready.value = 1 if random.random() < 0.6 else 0
            await RisingEdge(dut.seg_clk)
    _bg(backpressure())

    frames = [_rand_frame(n) for n in ([1, 16, 32, 33, 64, 65, 1518]
                                       + [random.randint(1, 600) for _ in range(25)])]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f))))
        await source.wait()
    _bg(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 500, "us")
        got.append(data)

    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, f" TX(bp) frame {i} mismatch exp={exp.hex()} act={act.hex()}"
    dut._log.info(f" TX back-pressure byte-exact PASS over {len(frames)} frames")

@cocotb.test()
async def test_tx_gated_before_enable(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    source = _tx_source(dut)

    async def drive():
        for _ in range(60):
            f = _rand_frame(128)
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f))))
    _bg(drive())

    beats = 0
    for _ in range(400):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ena.value):
            beats += 1
    assert int(dut.ctl_tx_enable.value) == 0, " ctl_tx_enable set while unaligned"
    assert beats == 0, f" {beats} segmented TX beats emitted before ctl_tx_enable"

    await _bringup(dut)
    seen = 0
    for _ in range(600):
        await RisingEdge(dut.seg_clk)
        if int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value):
            seen += 1
            if seen > 4:
                break
    assert seen > 4, " TX did not resume after alignment (gate dropped data?)"
    dut._log.info(f" TX gating PASS (0 beats before enable, {seen} after)")

@cocotb.test()
async def test_rx_gated_before_align(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)

    for _ in range(4):
        await src.send(_rand_frame(200))
        await src.idle_cycles(2)
    await ClockCycles(dut.rx_clk, 200)
    assert mon.empty(), " RX data forwarded to the core before alignment"

    await _bringup(dut)
    good = _rand_frame(300)
    await src.send(good)
    await src.idle_cycles(4)
    await ClockCycles(dut.rx_clk, 200)
    assert not mon.empty(), " RX stopped forwarding after alignment"
    assert _rx_frame(mon.recv_nowait(compact=False))[0] == good, \
        " first post-align frame corrupt"
    dut._log.info(" RX gating PASS (pre-align dropped, post-align byte-exact)")

@cocotb.test()
async def test_bringup_sequence(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    assert int(dut.tx_rst.value) == 1, " tx_rst not asserted out of reset"
    assert int(dut.rx_rst.value) == 1, ": rx_rst not asserted out of reset"

    await ClockCycles(dut.seg_clk, 20)
    assert int(dut.ctl_tx_send_lfi.value) == 1 and int(dut.ctl_tx_send_rfi.value) == 1, \
        " LFI/RFI not signalled while unaligned"
    assert int(dut.ctl_tx_enable.value) == 0, " TX enabled while unaligned"
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN, \
        f" FSM should wait for alignment, state={int(dut.fsm_state.value)}"
    assert int(dut.ctl_rx_enable.value) == 1, " ctl_rx_enable not set in WAIT_ALIGN"
    assert int(dut.ctl_rx_force_resync.value) == 0, " force_resync set unrequested"
    assert int(dut.tx_rst.value) == 1, " tx_rst deasserted before alignment"

    await _bringup(dut)
    assert int(dut.fsm_state.value) == S_XFER
    assert int(dut.ctl_tx_send_lfi.value) == 0 and int(dut.ctl_tx_send_rfi.value) == 0, \
        " LFI/RFI still asserted after alignment"
    assert int(dut.tx_rst.value) == 0, " tx_rst not released after alignment"
    assert int(dut.rx_rst.value) == 0, ": rx_rst not released after alignment"
    dut._log.info(" bring-up sequence PASS (both resets released)")

@cocotb.test()
async def test_align_loss_recovery(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)

    f0 = _rand_frame(256)
    await src.send(f0)
    await src.idle_cycles(4)

    dut.stat_rx_aligned.value = 0
    rx_rst_pulses = 0
    saw_lfi = 0
    for _ in range(120):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value):
            rx_rst_pulses += 1
        if int(dut.ctl_tx_send_lfi.value):
            saw_lfi += 1

    assert rx_rst_pulses == 0, (
        f"/ VIOLATED: an alignment dip on its own asserted the RX datapath reset for "
        f"{rx_rst_pulses} cycles. Only the sampler's window (or the host) may reach a reset, or "
        f"every FEC-corrected dip resets the port.")
    assert saw_lfi > 0, " LFI not re-asserted after alignment loss"
    assert int(dut.ctl_tx_enable.value) == 0, " TX still enabled after alignment loss"
    assert int(dut.tx_rst.value) == 1, " tx_rst not re-asserted after alignment loss"
    assert int(dut.fsm_state.value) == S_WAIT_ALIGN, \
        f": a dip must land in WAIT_ALIGN, not state {int(dut.fsm_state.value)}"

    dut.link_reset_req.value = 1
    n = 0
    for _ in range(32):
        await RisingEdge(dut.seg_clk)
        n += 1
        if int(dut.rx_datapath_reset.value):
            break
    assert int(dut.rx_datapath_reset.value) == 1, (
        " VIOLATED: `link_reset_req` did not reach the RX datapath reset. This is the ONE "
        "request port; the sampler's window and the host's CTL[3] both arrive on it.")
    assert int(dut.link_reset_ack.value) == 1, \
        ": `link_reset_ack` must be a LEVEL, high for the whole time the request is serviced"

    assert not hasattr(dut, "tx_datapath_reset"), (
        " `tx_datapath_reset` is back as a port of this module. The GT TX datapath reset is "
        "the host's alone, through the sequencer's pass-through; a second route re-creates the "
        "vendor exdes defect where a reset on one board un-aligned the partner.")
    assert not hasattr(dut, "tx_datapath_reset_req"), \
        ": a second reset requester port is back; every request enters through link_reset_req"

    held = 0
    for _ in range(RESET_CYC * 2):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value):
            held += 1
        elif held:
            break
    assert held >= RXDP_CYC - 2, (
        f" the RX datapath reset was held {held} seg_clk cycles, expected about "
        f"{RXDP_CYC} (T_RXDP_MS={T_RXDP_MS} x SEG_CYC_PER_MS={SEG_CYC_PER_MS}). The exact shape is "
        f"gated by ctl/sim/test_dcmac_mac_ctl_fsm_hold.py; this bound only says it is not a blip.")

    dut.link_reset_req.value = 0
    for _ in range(RESET_CYC * 2):
        await RisingEdge(dut.seg_clk)
        if int(dut.link_reset_ack.value) == 0 and int(dut.rx_datapath_reset.value) == 0:
            break
    assert int(dut.link_reset_ack.value) == 0, \
        ": the acknowledgement never fell, so the request was never fully serviced"

    await _bringup(dut)
    f1 = _rand_frame(512)
    await src.send(f1)
    await src.idle_cycles(4)
    await ClockCycles(dut.rx_clk, 300)
    got = [g[0] for g in _drain(mon)]
    assert f1 in got, f" no byte-exact frame after re-align (got {[len(g) for g in got]})"
    dut._log.info(f"/ re-align PASS (zero resets on the dip, then a requested RX-only "
                  f"reset held {held} seg_clk cycles, no TX datapath reset port at all)")

@cocotb.test()
async def test_reset_midframe(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)

    dut.rx_seg_valid.value = 1
    dut.rx_seg_dat.value = int.from_bytes(_rand_frame(32), "little")
    dut.rx_seg_ena.value = (1 << N_SEG) - 1
    dut.rx_seg_sop.value = 1
    dut.rx_seg_eop.value = 0
    dut.rx_seg_mty.value = 0
    await RisingEdge(dut.seg_clk)
    dut.rx_seg_valid.value = 0
    dut.rx_seg_sop.value = 0
    await ClockCycles(dut.seg_clk, 4)

    dut.seg_rstn.value = 0
    dut.tx_rstn.value = 0
    dut.rx_rstn.value = 0
    await ClockCycles(dut.seg_clk, 6)
    await ClockCycles(dut.tx_clk, 6)
    await ClockCycles(dut.rx_clk, 6)
    dut.seg_rstn.value = 1
    dut.tx_rstn.value = 1
    dut.rx_rstn.value = 1
    await ClockCycles(dut.seg_clk, 4)
    await _bringup(dut)

    frames = [_rand_frame(n) for n in (64, 100, 1518)]
    for f in frames:
        await src.send(f)
        await src.idle_cycles(3)
    await ClockCycles(dut.rx_clk, 400)

    got = [g[0] for g in _drain(mon)]
    assert got == frames, (f" post-reset traffic not byte-exact / fused frame present: "
                           f"sent={[len(f) for f in frames]} got={[len(g) for g in got]}")
    dut._log.info(" mid-frame reset PASS (partial frame discarded, recovery byte-exact)")

@cocotb.test()
async def test_short_frames_no_pad(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    shorts = [1, 2, 7, 14, 32, 59, 60, 61]
    frames = [_rand_frame(n) for n in shorts]

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f))))
        await source.wait()
    _bg(drive())

    for i, exp in enumerate(frames):
        data, err = await with_timeout(sink.recv(), 200, "us")
        assert len(data) == len(exp), \
            f": frame {i} length changed {len(exp)} -> {len(data)} (the seam padded)"
        assert data == exp, f": frame {i} not byte-exact"
    dut._log.info(f" no-pad PASS for lengths {shorts}")

@cocotb.test()
async def test_rx_overflow_sticky(dut):
    _start_clocks(dut, rx_mhz=25)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)

    assert int(dut.rx_overflow.value) == 0, " rx_overflow sticky before any traffic"
    for _ in range(80):
        await src.send(_rand_frame(1518))
    await ClockCycles(dut.seg_clk, 20)

    assert int(dut.rx_overflow.value) == 1, \
        " RX data was lost without raising rx_overflow (silent loss)"
    assert int(dut.rx_drop_frames.value) > 0, \
        "/: frames were lost but rx_drop_frames == 0"
    dut._log.info(f" overflow flag PASS (loss flagged, "
                  f"rx_drop_frames={int(dut.rx_drop_frames.value)})")

@cocotb.test()
async def test_tx_gapless(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    violations = []

    async def monitor():
        in_frame = False
        cyc = 0
        legal_ena = {(1 << (k + 1)) - 1 for k in range(N_SEG)}
        while True:
            await RisingEdge(dut.seg_clk)
            cyc += 1
            v = int(dut.tx_seg_valid.value)
            r = int(dut.tx_seg_ready.value)
            ena = int(dut.tx_seg_ena.value)
            eop = int(dut.tx_seg_eop.value)
            if in_frame and not v:
                violations.append(f"cycle {cyc}: tvalid dropped mid-frame")
                in_frame = False
            if v and ena not in legal_ena:
                violations.append(f"cycle {cyc}: interior ena gap, ena={ena:#b}")
            if v and r:
                if eop:
                    in_frame = False
                elif ena:
                    in_frame = True

    _bg(monitor())

    async def backpressure():
        while True:
            if random.random() < 0.25:
                dut.tx_seg_ready.value = 0
                await ClockCycles(dut.seg_clk, random.randint(1, 6))
            dut.tx_seg_ready.value = 1
            await ClockCycles(dut.seg_clk, random.randint(1, 8))
    _bg(backpressure())

    frames = [_rand_frame(n) for n in ([64, 65, 128, 200, 512, 513, 1518]
                                       + [random.randint(64, 1518) for _ in range(15)])]

    def pause_gen():
        while True:
            for _ in range(random.randint(1, 6)):
                yield False
            for _ in range(random.randint(1, 16)):
                yield True
    source.set_pause_generator(pause_gen())

    async def drive():
        for f in frames:
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f))))
            await ClockCycles(dut.tx_clk, random.randint(1, 16))
        await source.wait()
    _bg(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 1000, "us")
        got.append(data)

    assert not violations, f" violated ({len(violations)}): {violations[:6]}"
    for i, (exp, act) in enumerate(zip(frames, got)):
        assert exp == act, f" frame {i} not byte-exact under gaps"
    dut._log.info(f" gapless TX PASS over {len(frames)} frames, 0 violations "
                  f"(tx {TX_MHZ} MHz)")

@cocotb.test()
async def test_rx_err_flagged_and_forwarded(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    good = [_rand_frame(n) for n in (64, 300, 1518, 65)]
    bad = [_rand_frame(n) for n in (128, 700)]

    order = [(good[0], False), (bad[0], True), (good[1], False),
             (bad[1], True), (good[2], False), (good[3], False)]
    for f, err in order:
        await src.send(f, err=err)
        await src.idle_cycles(2)
    await ClockCycles(dut.rx_clk, 600)

    got = _drain(mon)

    assert [g[0] for g in got] == [f for f, _ in order], (
        ": the errored frames were not DELIVERED (this seam must not drop them -- "
        "the NIC core owns that decision). "
        f"expect lens={[len(f) for f, _ in order]} got={[len(g[0]) for g in got]}")
    for i, ((f, err), g) in enumerate(zip(order, got)):
        assert g[1] == (1 if err else 0), (
            f": frame {i} (len {len(f)}) tuser[0]={g[1]}, expected {1 if err else 0}")
        assert g[3] == 0, (
            f": frame {i} asserted tuser[0] on a beat BEFORE tlast; a consumer that "
            "samples tuser at tlast (both cores do) would see a partial indication")
    assert int(dut.rx_err_frames.value) == len(bad), \
        f": rx_err_frames={int(dut.rx_err_frames.value)}, expected {len(bad)}"
    assert int(dut.rx_drop_frames.value) == 0, (
        f": rx_drop_frames={int(dut.rx_drop_frames.value)} -- the seam DROPPED an "
        "errored frame. That is the reference behaviour and it is wrong natively.")
    dut._log.info(f" flag-and-forward PASS ({len(bad)} flagged at tlast, "
                  f"{len(order)} delivered byte-exact, 0 dropped)")

@cocotb.test()
async def test_rx_err_midframe_flagged_on_tlast(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    good0, good1, good2 = _rand_frame(64), _rand_frame(300), _rand_frame(1518)
    bad_first = _rand_frame(256)
    bad_mid = _rand_frame(512)
    bad_seg1 = _rand_frame(128)

    order = [(good0, None, 0), (bad_first, 0, 0), (good1, None, 0),
             (bad_mid, 5, 0), (good2, None, 0), (bad_seg1, 1, 1)]
    for f, eb, es in order:
        await src.send(f, err_beat=eb, err_seg=es)
        await src.idle_cycles(2)
    await ClockCycles(dut.rx_clk, 1200)

    got = _drain(mon)
    assert [g[0] for g in got] == [f for f, _, _ in order], (
        "/: not every frame was delivered byte-exact and in order. "
        f"expect lens={[len(f) for f, _, _ in order]} got={[len(g[0]) for g in got]}")
    for i, ((f, eb, _es), g) in enumerate(zip(order, got)):
        want = 0 if eb is None else 1
        assert g[1] == want, (
            ": an RX error flagged before the final AXIS beat did not "
            "reach the tlast beat. rx_seg_err is only being honoured when it coincides "
            f"with tlast. frame {i} (len {len(f)}, err_beat={eb}) tuser[0]={g[1]}, "
            f"expected {want}")
    dut._log.info(f" PASS -- {sum(1 for _, eb, _ in order if eb is not None)} "
                  "mid-frame errors flagged on tlast, all frames delivered byte-exact")

@cocotb.test()
async def test_rx_err_midframe_counted(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    assert int(dut.rx_err_frames.value) == 0, "X6: rx_err_frames non-zero before traffic"

    n_bad = 4
    for _ in range(n_bad):
        await src.send(_rand_frame(256), err_beat=0)
        await src.idle_cycles(2)
    await ClockCycles(dut.rx_clk, 900)

    err_cnt = int(dut.rx_err_frames.value)
    assert err_cnt == n_bad, (
        "X6: a mid-frame RX error was not counted. "
        f"rx_err_frames={err_cnt}, expected {n_bad} -- the counter samples tuser only when "
        "rxa_tlast is high.")
    assert int(dut.rx_drop_frames.value) == 0, \
        f": rx_drop_frames={int(dut.rx_drop_frames.value)}, expected 0"
    assert len(_drain(mon)) == n_bad, ": errored frames not delivered"
    dut._log.info(f"X6 PASS -- rx_err_frames={err_cnt}, all {n_bad} delivered, 0 dropped")

@cocotb.test()
async def test_ns4_flag_with_selected_frame_fifo_storage(dut):
    want_bram = os.environ.get("FF_BRAM", "0") == "1"

    adapter = dut.u_adapter if hasattr(dut, "u_adapter") else dut
    ff = adapter.u_rx_frame_fifo
    have_bram = hasattr(ff, "g_bram_read")
    assert have_bram == want_bram, (
        f"FF_BRAM={os.environ.get('FF_BRAM')} but g_bram_read "
        f"{'exists' if have_bram else 'does not exist'} -- MEM_STYLE plumbing is broken")
    if have_bram:
        assert hasattr(ff.g_bram_read, "rd_word_valid"), \
            "g_bram_read has no rd_word_valid: this is not a registered-read FIFO"

    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    lens = [64, 128, 200, 64, 512, 97, 1518, 64]
    errs = [False, True, False, True, False, False, True, False]
    frames = [_rand_frame(n) for n in lens]
    for f, e in zip(frames, errs):
        await src.send(f, err=e)
    await ClockCycles(dut.rx_clk, 2000)

    got = _drain(mon)
    assert [g[0] for g in got] == frames, (
        f" under {'block' if have_bram else 'distributed'} storage: "
        f"expect lens={lens} got={[len(g[0]) for g in got]}")
    for i, (e, g) in enumerate(zip(errs, got)):
        assert g[1] == (1 if e else 0), \
            f" under {'block' if have_bram else 'distributed'}: frame {i} flag {g[1]}"
    n_bad = sum(errs)
    assert int(dut.rx_err_frames.value) == n_bad, \
        f"rx_err_frames={int(dut.rx_err_frames.value)} expected {n_bad}"
    assert int(dut.rx_drop_frames.value) == 0, \
        f"rx_drop_frames={int(dut.rx_drop_frames.value)} expected 0"
    dut._log.info(f" PASS with storage={'block' if have_bram else 'distributed'}: "
                  f"{n_bad} flagged, {len(frames)} delivered byte-exact back-to-back")

@cocotb.test()
async def test_rx_no_tready_port(dut):
    for name in ("m_axis_rx_tready", "m_rx_axis_tready", "rx_axis_tready"):
        assert not hasattr(dut, name), \
            f": the seam still has an RX back-pressure port `{name}`"

    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    frames = [_rand_frame(n) for n in (64, 128, 1518, 65, 512)]
    for f in frames:
        await src.send(f)
        await src.idle_cycles(2)
    await ClockCycles(dut.rx_clk, 600)

    got = [g[0] for g in _drain(mon)]
    assert got == frames, (f": push-only delivery is not byte-exact. "
                           f"sent={[len(f) for f in frames]} got={[len(g) for g in got]}")
    dut._log.info(f" PASS -- no RX tready port exists, {len(got)} frames pushed "
                  "byte-exact")

@cocotb.test()
async def test_txrst_latency(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    edges = 0
    for _ in range(12):
        await RisingEdge(dut.tx_clk)
        assert int(dut.tx_rst.value) == 1, " tx_rst deasserted while unaligned"
        edges += 1
    assert edges >= 8, " fewer than 8 tx_clk edges observed while tx_rst was asserted"

    await _bringup(dut)
    assert int(dut.tx_rst.value) == 0, " tx_rst not released after alignment"

    dut.stat_rx_aligned.value = 0
    n = 0
    for _ in range(8):
        await RisingEdge(dut.tx_clk)
        n += 1
        if int(dut.tx_rst.value) == 1:
            break
    assert int(dut.tx_rst.value) == 1 and n <= 4, \
        f" tx_rst took {n} tx_clk cycles to re-assert (limit 4)"
    dut._log.info(f"/ PASS (>=8 tx_clk edges before release; re-assert in {n} cycles "
                  f"at {TX_MHZ} MHz)")

@cocotb.test()
async def test_rxrst_latency(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)

    edges = 0
    for _ in range(12):
        await RisingEdge(dut.rx_clk)
        assert int(dut.rx_rst.value) == 1, ": rx_rst deasserted while unaligned"
        edges += 1
    assert edges >= 8, ": fewer than 8 rx_clk edges observed while rx_rst was asserted"

    await _bringup(dut)
    assert int(dut.rx_rst.value) == 0, ": rx_rst not released after alignment"

    dut.stat_rx_aligned.value = 0
    n = 0
    for _ in range(8):
        await RisingEdge(dut.rx_clk)
        n += 1
        if int(dut.rx_rst.value) == 1:
            break
    assert int(dut.rx_rst.value) == 1 and n <= 4, \
        f": rx_rst took {n} rx_clk cycles to re-assert (limit 4)"
    dut._log.info(f" rx_rst PASS (>=8 rx_clk edges before release; re-assert in {n} "
                  f"cycles at {RX_MHZ} MHz) -- and it is INDEPENDENT of tx_clk")

@cocotb.test()
async def test_port_group_reset(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    expect = sum(1 << p for p in range(ANCHOR, ANCHOR + NPORTS))

    dut.link_reset_req.value = 1
    seen = None
    for _ in range(64):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value):
            seen = int(dut.rx_datapath_reset_ports.value)
            break
    assert seen is not None, \
        " no RX datapath reset observed after a `link_reset_req` ('s one request port)"
    assert seen == expect, (f" reset vector {seen:#08b} != expected {expect:#08b} "
                            f"(ANCHOR={ANCHOR}, NPORTS={NPORTS})")

    dut.link_reset_req.value = 0
    for _ in range(RESET_CYC * 3):
        await RisingEdge(dut.seg_clk)
        if int(dut.rx_datapath_reset.value) == 0 and int(dut.link_reset_ack.value) == 0:
            break
    await _bringup(dut)
    await ClockCycles(dut.seg_clk, 4)
    assert int(dut.rx_datapath_reset_ports.value) == 0, \
        " reset vector non-zero while no reset requested"
    dut._log.info(f" PASS (ANCHOR={ANCHOR}, NPORTS={NPORTS}, vector={seen:#08b})")

@cocotb.test()
async def test_rx_frames_whole_under_slow_rxclk(dut):
    _start_clocks(dut, rx_mhz=50)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    lens = [64, 65, 63, 128, 129, 1518, 97, 512, 511, 66, 1500, 64,
            333, 1024, 127, 200, 65, 999, 64, 1518]
    REPS = 20
    frames = [_rand_frame(n) for _ in range(REPS) for n in lens]

    for f in frames:
        await src.send(f)
    await src.idle_cycles(4)
    await ClockCycles(dut.rx_clk, 4000)

    got = [g[0] for g in _drain(mon)]

    sent_set = set(frames)
    for i, g in enumerate(got):
        assert g in sent_set, (
            f"X1/X2: delivered frame #{i} (len {len(g)}) is not any frame that was sent -- "
            "it is a truncation, a fusion of two frames, or corrupt. "
            f"got lens={[len(x) for x in got]}")

    it = iter(frames)
    assert all(any(g == s for s in it) for g in got), (
        f"X9: delivered frames are not an order-preserving subsequence of the sent frames. "
        f"sent {len(frames)} frames, got lens={[len(x) for x in got]}")

    dropped = int(dut.rx_drop_frames.value)
    assert dropped > 0, (
        "X3: no frame was dropped -- rx_clk was not starved hard enough for this test to "
        "be meaningful (it would pass trivially on a truncating design too)")
    assert int(dut.rx_overflow.value) == 1, "X8: frames dropped without rx_overflow sticky"
    assert len(got) + dropped == len(frames), (
        f"X7/X8: accounting -- delivered {len(got)} + rx_drop_frames {dropped} != "
        f"{len(frames)} sent. A frame vanished without being counted, or was double-counted.")

    dut._log.info(f"/X1/X2/X3/X8/X9 PASS -- {len(got)} of {len(frames)} frames "
                  f"delivered whole and in order, {dropped} dropped whole and counted, "
                  "0 partial, 0 fused")

@cocotb.test()
async def test_tx_abort_maps_to_seg_err(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    plan = [(64, None), (128, -1), (300, None), (256, 0), (1518, -1), (65, None)]
    frames = [(_rand_frame(n), ab) for n, ab in plan]

    async def drive():
        for f, ab in frames:
            nbeats = (len(f) + BYTE_LANES - 1) // BYTE_LANES
            beat = None if ab is None else (nbeats - 1 if ab < 0 else ab)
            await source.send(AxiStreamFrame(tdata=f,
                                             tuser=_tx_tuser(len(f), abort_beat=beat)))
        await source.wait()
    _bg(drive())

    got = []
    for _ in range(len(frames)):
        data, err = await with_timeout(sink.recv(), 500, "us")
        got.append((data, err))

    for i, ((f, ab), (data, err)) in enumerate(zip(frames, got)):
        assert data == f, (f": TX frame {i} not byte-exact under abort "
                           f"(len exp {len(f)} act {len(data)})")
        want = 0 if ab is None else 1
        assert err == want, (
            f": TX frame {i} (len {len(f)}, abort_beat={ab}) had tx_seg_err={err}, "
            f"expected {want} on the EOP segment")
    dut._log.info(f" PASS -- {sum(1 for _, ab in plan if ab is not None)} aborts "
                  f"mapped to tx_seg_err on the EOP segment (including a MID-frame one), "
                  f"{len(frames)} byte-exact")

@cocotb.test()
async def test_tx_cpl_tag_roundtrip(dut):
    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    if not TX_CPL_EN:
        for _ in range(200):
            await RisingEdge(dut.tx_clk)
            assert int(dut.m_axis_tx_cpl_valid.value) == 0, \
                ": a completion was emitted with PTP_TS_EN=0 and TX_TAG_W=0"
        dut._log.info(" PASS (negative variant: no completion path, valid tied 0)")
        return

    source = _tx_source(dut)
    sink = SegmentedSink(dut, dut.seg_clk, N_SEG, SEG_W)

    async def ptp_tick():
        t = 1
        while True:
            await RisingEdge(dut.seg_clk)
            dut.seg_ptp_time.value = t
            t = (t + 1) & ((1 << PTP_TS_W) - 1)
    _bg(ptp_tick())

    cpl = []

    async def cpl_collect():
        while True:
            await RisingEdge(dut.tx_clk)
            if int(dut.m_axis_tx_cpl_valid.value) and \
                    int(dut.m_axis_tx_cpl_ready.value):
                cpl.append((int(dut.m_axis_tx_cpl_tag.value),
                            int(dut.m_axis_tx_cpl_ts.value)))
    _bg(cpl_collect())

    tag_mask = (1 << TX_TAG_W) - 1 if TX_TAG_W > 0 else 0
    n = 8
    frames = [_rand_frame(random.randint(64, 700)) for _ in range(n)]
    tags = [((i * 37 + 5) & tag_mask) for i in range(n)]

    async def drive():
        for f, tg in zip(frames, tags):
            await source.send(AxiStreamFrame(tdata=f, tuser=_tx_tuser(len(f), tag=tg)))
        await source.wait()
    _bg(drive())

    for _ in range(n):
        await with_timeout(sink.recv(), 500, "us")
    await ClockCycles(dut.tx_clk, 400)

    assert len(cpl) == n, (f": {len(cpl)} completions for {n} transmitted frames -- "
                           "one per frame is required")
    if TX_TAG_W > 0:
        assert [c[0] for c in cpl] == tags, (
            f": the tags did not round-trip. sent={tags} got={[c[0] for c in cpl]}")
    stamps = [c[1] for c in cpl]
    assert all(s != 0 for s in stamps), \
        f": a completion carried timestamp 0 while seg_ptp_time was running: {stamps}"
    assert len(set(stamps)) == n, \
        f": completions share a timestamp (stale capture?): {stamps}"
    assert int(dut.tx_cpl_overflow.value) == 0, \
        ": tx_cpl_overflow raised while the consumer was always ready"
    dut._log.info(f" PASS -- {n}/{n} completions, tags round-tripped, "
                  f"{len(set(stamps))} distinct timestamps")

@cocotb.test()
async def test_rx_ptp_ts_field(dut):
    assert len(dut.m_axis_rx_tuser) == RX_USER_W, (
        f": m_axis_rx_tuser is {len(dut.m_axis_rx_tuser)} bits, expected {RX_USER_W} "
        f"for PTP_TS_EN={PTP_TS_EN} PTP_TS_W={PTP_TS_W}")

    _start_clocks(dut)
    await _reset(dut, aligned=0)
    await _bringup(dut)

    src = SegmentedSource(dut, dut.seg_clk, N_SEG, SEG_W)
    mon = _rx_monitor(dut)
    await src.idle_cycles(8)

    if not PTP_TS_EN:
        frames = [_rand_frame(n) for n in (64, 300)]
        for f in frames:
            await src.send(f)
            await src.idle_cycles(2)
        await ClockCycles(dut.rx_clk, 400)
        got = _drain(mon)
        assert [g[0] for g in got] == frames, " negative variant: frames not byte-exact"
        for g in got:
            assert g[2] == 0, f": a timestamp field appeared with PTP_TS_EN=0: {g[2]}"
        dut._log.info(" PASS (negative variant: RX_USER_W==1, no timestamp field)")
        return

    stamps_sent = []
    frames = [_rand_frame(n) for n in (64, 300, 1518, 65)]
    for i, f in enumerate(frames):
        t = 0x1000 + i * 0x111
        dut.seg_ptp_time.value = t
        stamps_sent.append(t)
        await src.send(f)
        await src.idle_cycles(3)
    await ClockCycles(dut.rx_clk, 1200)

    got = _drain(mon)
    assert [g[0] for g in got] == frames, ": frames not byte-exact with PTP enabled"
    assert [g[2] for g in got] == stamps_sent, (
        f": the timestamp captured at SOP did not ride the frame. "
        f"sent={[hex(s) for s in stamps_sent]} got={[hex(g[2]) for g in got]}")
    dut._log.info(f" PASS -- RX_USER_W={RX_USER_W}, {len(got)} per-frame timestamps "
                  "captured at SOP and delivered on tlast")

@cocotb.test()
async def test_mac_status_exported(dut):
    for name in ("rx_status", "tx_status", "link_up", "carrier", "link_reset_ack",
                 "rx_overflow", "rx_trunc", "rx_err_frames", "rx_drop_frames",
                 "tx_cpl_overflow"):
        assert hasattr(dut, name), f": `{name}` is not a port of the seam"
    assert len(dut.rx_err_frames) == 32 and len(dut.rx_drop_frames) == 32, \
        ": the frame counters must be 32 bits"

    _start_clocks(dut)
    await _reset(dut, aligned=0)

    assert int(dut.link_up.value) == 0, ": link_up set while unaligned"
    assert int(dut.carrier.value) == 0, ": carrier set while unaligned"
    assert int(dut.rx_status.value) == 0, ": rx_status set while unaligned"
    assert int(dut.tx_status.value) == 0, ": tx_status set while unaligned"

    await _bringup(dut)
    assert int(dut.link_up.value) == 1, ": link_up clear after alignment"
    assert int(dut.carrier.value) == 1, ": carrier clear after alignment"
    assert int(dut.rx_status.value) == 1, ": rx_status clear after alignment"
    assert int(dut.tx_status.value) == 1, ": tx_status clear after alignment"

    dut.stat_rx_aligned.value = 0
    nrx = ntx = None
    for i in range(1, 13):
        await RisingEdge(dut.rx_clk)
        if nrx is None and int(dut.rx_status.value) == 0:
            nrx = i
        if ntx is None and int(dut.tx_status.value) == 0:
            ntx = i
        if nrx is not None and ntx is not None:
            break
    assert nrx is not None and nrx <= 6, f": rx_status took {nrx} cycles to fall"
    assert ntx is not None, ": tx_status never fell after alignment loss"
    dut._log.info(f" PASS -- 8 status ports exported; rx_status fell in {nrx} "
                  f"rx_clk cycles, tx_status observed low as well")
