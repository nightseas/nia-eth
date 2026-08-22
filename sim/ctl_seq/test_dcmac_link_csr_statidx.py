# ---------------------------------------------------------------------------
# File        : test_dcmac_link_csr_statidx.py
# Description : The statistics index tests: an in range index reads its entry, an out of
#               range index reads zero and sets both indications, the sticky is write one
#               to clear and does not disturb the index, and a read only field ignores a
#               write.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

STAT_IDX_MAX = int(os.environ.get("STAT_IDX_MAX", "43"))
STATS_PER = 22

A_VERSION = 0x004
A_STATIDX = 0x034
A_STATDATA = 0x038

VERSION_EXPECT = 0x0003_0000

CLK_NS = 8
SEG_NS = 3
TX_NS = 4
RX_NS = 4

async def _start(dut):
    cocotb.start_soon(Clock(dut.axil_aclk, CLK_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.seg_clk, SEG_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.tx_clk, TX_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.rx_clk, RX_NS, units="ns").start())

    dut.axil_aresetn.value = 0
    dut.seg_rstn.value = 0
    dut.tx_rstn.value = 0
    dut.rx_rstn.value = 0
    for sig, val in (("s_axil_awaddr", 0), ("s_axil_awvalid", 0), ("s_axil_wdata", 0),
                     ("s_axil_wstrb", 0), ("s_axil_wvalid", 0), ("s_axil_bready", 0),
                     ("s_axil_araddr", 0), ("s_axil_arvalid", 0), ("s_axil_rready", 0),
                     ("link_up", 0), ("mac_fsm_state", 0),
                     ("rx_status", 0), ("tx_status", 0), ("ctl_link_fault", 0),
                     ("ctl_access_fault", 0), ("ctl_seq_busy", 0), ("ctl_rx_phy_status", 0),
                     ("ctl_retry_cnt", 0), ("ctl_seq_state", 0), ("ctl_seq_pc", 0)):
        getattr(dut, sig).value = val
    await ClockCycles(dut.axil_aclk, 8)
    dut.axil_aresetn.value = 1
    dut.seg_rstn.value = 1
    dut.tx_rstn.value = 1
    dut.rx_rstn.value = 1
    await ClockCycles(dut.axil_aclk, 8)

async def _wr(dut, addr, data, strb=0xF):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = strb
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1
    aw, w = False, False
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
    assert aw and w, f"write to 0x{addr:03x} never handshook (aw={aw} w={w})"
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_bvalid.value):
            dut.s_axil_bready.value = 0
            await RisingEdge(dut.axil_aclk)
            return
    raise AssertionError(f"write to 0x{addr:03x} never returned bvalid")

async def _rd(dut, addr):
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value = 1
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_arready.value):
            dut.s_axil_arvalid.value = 0
            break
    else:
        raise AssertionError(f"read of 0x{addr:03x} never got arready")
    for _ in range(64):
        await RisingEdge(dut.axil_aclk)
        if int(dut.s_axil_rvalid.value):
            val = int(dut.s_axil_rdata.value)
            dut.s_axil_rready.value = 0
            await RisingEdge(dut.axil_aclk)
            return val
    raise AssertionError(f"read of 0x{addr:03x} never returned rvalid")

def _f(val, hi, lo):
    return (val >> lo) & ((1 << (hi - lo + 1)) - 1)

async def _settle_snap(dut):
    await ClockCycles(dut.axil_aclk, 64)

@cocotb.test()
async def test_ns52_in_range_index_reads_its_entry(dut):
    await _start(dut)
    idxs = sorted({i for i in (0, 1, STATS_PER - 1, STATS_PER, STAT_IDX_MAX) if i <= STAT_IDX_MAX})
    assert idxs, f"no legal index at STAT_IDX_MAX={STAT_IDX_MAX}: the variant is vacuous"
    for idx in idxs:
        await _wr(dut, A_STATIDX, idx)
        await _settle_snap(dut)
        v = await _rd(dut, A_STATIDX)
        assert _f(v, 7, 0) == idx, (
            f" VIOLATED: wrote STATIDX={idx}, read back {_f(v, 7, 0)}. The low byte is "
            f"read/write and unchanged by this clause.")
        assert _f(v, 31, 31) == 0, (
            f" VIOLATED: index {idx} is within STAT_IDX_MAX={STAT_IDX_MAX} and reported "
            f"out of range. A bound that rejects legal indices is worse than no bound.")
        assert _f(v, 30, 30) == 0, (
            f" VIOLATED: index {idx} set the sticky out-of-range bit. reg=0x{v:08x}")
        assert int(dut.ctl_stat_rd_idx.value) == idx, (
            f": `ctl_stat_rd_idx` reads {int(dut.ctl_stat_rd_idx.value)} for index {idx}. The "
            f"index must still reach the sequencer, which is what does the array lookup.")
    print(f"NIA_NS52 in_range STAT_IDX_MAX={STAT_IDX_MAX} STATS_PER={STATS_PER}", flush=True)

@cocotb.test()
async def test_ns52_out_of_range_index_reads_zero(dut):
    if STAT_IDX_MAX >= 255:
        print(f"NIA_SKIP test_ns52_out_of_range_index_reads_zero: STAT_IDX_MAX={STAT_IDX_MAX} "
              f"leaves no out-of-range index in an 8-bit field; the bounded variants are "
              f"`make -f Makefile.statidx` (43) and `STAT_IDX_MAX=21`.", flush=True)
        return
    await _start(dut)
    dut.ctl_stat_rd_data.value = 0xDEADBEEF
    await _settle_snap(dut)

    await _wr(dut, A_STATIDX, STAT_IDX_MAX)
    await _settle_snap(dut)
    good = await _rd(dut, A_STATDATA)
    assert good == 0xDEADBEEF, (
        f"the test is vacuous: at the highest legal index STATDATA read 0x{good:08x}, not the "
        f"0xDEADBEEF driven on `ctl_stat_rd_data`. The snapshot has not settled or the read mux is "
        f"wrong, and either way the masking assertion below would pass for the wrong reason.")

    for idx in (STAT_IDX_MAX + 1, STAT_IDX_MAX + 2, 255):
        if idx > 255 or idx <= STAT_IDX_MAX:
            continue
        await _wr(dut, A_STATIDX, idx)
        await _settle_snap(dut)
        v = await _rd(dut, A_STATDATA)
        assert v == 0, (
            f" VIOLATED: index {idx} is above STAT_IDX_MAX={STAT_IDX_MAX} and STATDATA read "
            f"0x{v:08x}. An out-of-range index must read 0, not a plausible number from elsewhere "
            f"in the snapshot - that is.")
    print(f"NIA_NS52 out_of_range masked above {STAT_IDX_MAX}", flush=True)

@cocotb.test()
async def test_ns52_out_of_range_sets_both_indications(dut):
    if STAT_IDX_MAX >= 255:
        print(f"NIA_SKIP test_ns52_out_of_range_sets_both_indications: STAT_IDX_MAX={STAT_IDX_MAX} "
              f"leaves no out-of-range index in an 8-bit field.", flush=True)
        return
    await _start(dut)
    await _wr(dut, A_STATIDX, 0)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 30, 30) == 0, f"sticky was set out of reset: 0x{v:08x}"

    bad = STAT_IDX_MAX + 1
    await _wr(dut, A_STATIDX, bad)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 31, 31) == 1, (
        f" VIOLATED: index {bad} > STAT_IDX_MAX={STAT_IDX_MAX} and bit [31] read 0. "
        f"reg=0x{v:08x}")
    assert _f(v, 30, 30) == 1, (
        f" VIOLATED: index {bad} did not latch the sticky bit [30]. reg=0x{v:08x}")

    await _wr(dut, A_STATIDX, 0)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 31, 31) == 0, (
        f" VIOLATED: bit [31] is the CURRENT index's status and must fall on a legal index. "
        f"reg=0x{v:08x}")
    assert _f(v, 30, 30) == 1, (
        f" VIOLATED: bit [30] is sticky and must survive a legal index. A history bit that "
        f"clears itself records nothing. reg=0x{v:08x}")
    print(f"NIA_NS52 indications now/sticky separate, bad={bad}", flush=True)

@cocotb.test()
async def test_ns52_sticky_is_w1c_and_does_not_disturb_idx(dut):
    if STAT_IDX_MAX >= 255:
        print(f"NIA_SKIP test_ns52_sticky_is_w1c_and_does_not_disturb_idx: STAT_IDX_MAX="
              f"{STAT_IDX_MAX} leaves no out-of-range index to set the sticky bit with.", flush=True)
        return
    await _start(dut)
    bad = STAT_IDX_MAX + 1
    await _wr(dut, A_STATIDX, bad)
    await _settle_snap(dut)
    await _wr(dut, A_STATIDX, 7)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 7, 0) == 7 and _f(v, 30, 30) == 1, f"precondition not met: 0x{v:08x}"

    await _wr(dut, A_STATIDX, 1 << 30)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 30, 30) == 0, (
        f" VIOLATED: writing 1 to bit [30] did not clear it. reg=0x{v:08x}")
    assert _f(v, 7, 0) == 7, (
        f" VIOLATED: the W1C to bit [30] changed STATIDX[7:0] from 7 to {_f(v, 7, 0)}. "
        f"Clearing an indication must not move the index.")
    assert int(dut.ctl_stat_rd_idx.value) == 7, (
        f" VIOLATED: the W1C disturbed `ctl_stat_rd_idx` "
        f"({int(dut.ctl_stat_rd_idx.value)}).")
    print("NIA_NS52 w1c clears [30] and preserves [7:0]", flush=True)

@cocotb.test()
async def test_ns52_readonly_fields_ignore_writes(dut):
    await _start(dut)
    await _wr(dut, A_STATIDX, 0)
    await _settle_snap(dut)
    v = await _rd(dut, A_STATIDX)
    assert _f(v, 15, 8) == STATS_PER, (
        f" VIOLATED: STATIDX[15:8] must read STATS_PER={STATS_PER}, read {_f(v, 15, 8)}. "
        f"That number is the index order's divisor (: k/2 = register, k%2 = half).")
    assert _f(v, 23, 16) == STAT_IDX_MAX, (
        f" VIOLATED: STATIDX[23:16] must read STAT_IDX_MAX={STAT_IDX_MAX}, read "
        f"{_f(v, 23, 16)}.")

    await _wr(dut, A_STATIDX, 0xBFFF_FF00 | 3)
    await _settle_snap(dut)
    v2 = await _rd(dut, A_STATIDX)
    assert _f(v2, 15, 8) == STATS_PER and _f(v2, 23, 16) == STAT_IDX_MAX, (
        f" VIOLATED: a write of 0xBFFFFF03 changed the read-only map fields. "
        f"reg=0x{v2:08x}")
    assert _f(v2, 7, 0) == 3, f"the low byte did not take the write: 0x{v2:08x}"
    assert _f(v2, 29, 24) == 0, f"reserved bits [29:24] must read 0: 0x{v2:08x}"

    await _wr(dut, A_STATIDX, 0xFFFF_FF00 | 5)
    await _settle_snap(dut)
    v3 = await _rd(dut, A_STATIDX)
    assert _f(v3, 7, 0) == 3, (
        f" VIOLATED: a word carrying the W1C bit [30] moved the index from 3 to "
        f"{_f(v3, 7, 0)}. reg=0x{v3:08x}")
    print(f"NIA_NS52 readonly map STATS_PER={STATS_PER} STAT_IDX_MAX={STAT_IDX_MAX}", flush=True)

@cocotb.test()
async def test_ns52_default_max_restricts_nothing(dut):
    if STAT_IDX_MAX != 255:
        print(f"NIA_SKIP test_ns52_default_max_restricts_nothing: needs STAT_IDX_MAX=255 "
              f"(have {STAT_IDX_MAX}); run `make -f Makefile.statidx defaultmax`.", flush=True)
        return
    await _start(dut)
    dut.ctl_stat_rd_data.value = 0x0BADC0DE
    await _settle_snap(dut)
    rnd = random.Random(20260806)
    for idx in [0, 1, 22, 30, 43, 44, 127, 254, 255] + [rnd.randrange(256) for _ in range(8)]:
        await _wr(dut, A_STATIDX, idx)
        await _settle_snap(dut)
        v = await _rd(dut, A_STATIDX)
        assert _f(v, 31, 31) == 0 and _f(v, 30, 30) == 0, (
            f" VIOLATED: at the default STAT_IDX_MAX=255, index {idx} was reported out of "
            f"range (reg=0x{v:08x}). The default must impose no restriction.")
        d = await _rd(dut, A_STATDATA)
        assert d == 0x0BADC0DE, (
            f" VIOLATED: at the default STAT_IDX_MAX=255, index {idx} masked STATDATA to "
            f"0x{d:08x}. The bound at the CSR is what changes; the sequencer's own "
            f"`stat_rd_idx < N_STAT` check is what still returns 0 above N_STAT.")
    print("NIA_NS52 default max restricts nothing", flush=True)

@cocotb.test()
async def test_ns52_version_reports_the_new_layout(dut):
    await _start(dut)
    v = await _rd(dut, A_VERSION)
    assert v == VERSION_EXPECT, (
        f" VIOLATED: VERSION reads 0x{v:08x}, expected 0x{VERSION_EXPECT:08x}. A layout that "
        f"changes without a version bump makes every consumer guess, and `nia-portstat` decodes by "
        f"this word.")
    print(f"NIA_NS52 version=0x{v:08x}", flush=True)
