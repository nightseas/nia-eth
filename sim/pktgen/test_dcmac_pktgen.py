# ---------------------------------------------------------------------------
# File        : test_dcmac_pktgen.py
# Description : The loopback tests of the segmented instrument: identity and bus check,
#               byte exactness at fixed and random length, and the frame header inserted
#               ahead of the payload and absent when it is disabled.
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
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

N_SEG = int(os.environ.get("N_SEG", "2"))
SEG_W = int(os.environ.get("SEG_W", "128"))
STALL_CYC = int(os.environ.get("STALL_CYC", "16"))
LEN_MIN_HW = int(os.environ.get("LEN_MIN_HW", "60"))
LEN_MAX_HW = int(os.environ.get("LEN_MAX_HW", "9018"))
SEG_MHZ = int(os.environ.get("SEG_MHZ", "390"))
AXIL_MHZ = int(os.environ.get("AXIL_MHZ", "250"))

SEG_B = SEG_W // 8
BEAT_B = N_SEG * SEG_B

R_MODULE_TYPE = 0x00
R_MAP_VERSION = 0x04
R_BUS_CHECK = 0x08
R_SEG_GEOMETRY = 0x0C
R_FEATURES = 0x10
R_CTL = 0x14
R_STATUS = 0x18
R_LEN_MIN = 0x1C
R_LEN_MAX = 0x20
R_LEN_MODE = 0x24
R_LEN_EFFECTIVE = 0x28
R_LEN_CLAMP_STICKY = 0x2C
R_TX_FRAME_LIMIT = 0x30
R_SNAPSHOT_ROUNDS = 0x34
R_TX_FRAMES = 0x40
R_TX_BYTES = 0x44
R_RX_FRAMES = 0x48
R_RX_BYTES = 0x4C
R_RX_ERR_FRAMES = 0x50
R_RX_MISMATCH_BEATS = 0x54
R_STALL_CYCLE = 0x58
R_LATCHED_TX_FRAMES = 0x60
R_LATCHED_TX_BYTES = 0x64
R_LATCHED_RX_FRAMES = 0x68
R_LATCHED_RX_BYTES = 0x6C
R_LATCHED_RX_MISMATCH = 0x70

MODULE_TYPE_VALUE = 0x4E535047
MAP_VERSION_MAJOR = 3

CTL_ENABLE = 1 << 0
CTL_CLEAR = 1 << 1

ST_BUSY = 1 << 0
ST_DONE = 1 << 1
ST_STALL = 1 << 2
ST_UNDERFLOW = 1 << 3
ST_OVERFLOW = 1 << 4
ST_LOCKED = 1 << 5
ST_LINK = 1 << 6

R_HDR_CTL = 0x80
R_HDR_DST_MAC_LOW = 0x84
R_HDR_DST_MAC_HIGH = 0x88
R_HDR_SRC_MAC_LOW = 0x8C
R_HDR_SRC_MAC_HIGH = 0x90
R_HDR_ETHERTYPE = 0x94
R_HDR_IP_VERSION_TOS = 0x98
R_HDR_IP_ID_FLAGS = 0x9C
R_HDR_IP_TTL_PROTOCOL = 0xA0
R_HDR_IP_SRC_ADDR = 0xA4
R_HDR_IP_DST_ADDR = 0xA8
R_HDR_UDP_PORTS = 0xAC

HDR_CTL_ENABLE = 1 << 0
FEATURE_HDR = 1 << 0
HDR_B = 42

MODE_FIXED = 0
MODE_RAND = 1


class Axil:
    def __init__(self, dut):
        self.dut = dut

    async def write(self, addr, value):
        d = self.dut
        d.s_axil_awaddr.value = addr
        d.s_axil_awvalid.value = 1
        d.s_axil_wdata.value = value
        d.s_axil_wstrb.value = 0xF
        d.s_axil_wvalid.value = 1
        d.s_axil_bready.value = 1
        for _ in range(200):
            await RisingEdge(d.axil_aclk)
            if d.s_axil_bvalid.value:
                d.s_axil_awvalid.value = 0
                d.s_axil_wvalid.value = 0
                await ClockCycles(d.axil_aclk, 2)
                d.s_axil_bready.value = 0
                return
        raise AssertionError(f"write to 0x{addr:03x} did not complete")

    async def read(self, addr):
        d = self.dut
        d.s_axil_araddr.value = addr
        d.s_axil_arvalid.value = 1
        d.s_axil_rready.value = 1
        for _ in range(200):
            await RisingEdge(d.axil_aclk)
            if d.s_axil_rvalid.value:
                value = int(d.s_axil_rdata.value)
                d.s_axil_arvalid.value = 0
                await ClockCycles(d.axil_aclk, 1)
                d.s_axil_rready.value = 0
                return value
        raise AssertionError(f"read from 0x{addr:03x} did not complete")


async def start(dut):
    cocotb.start_soon(Clock(dut.seg_clk, round(1000 / SEG_MHZ), units="ns").start())
    cocotb.start_soon(Clock(dut.axil_aclk, round(1000 / AXIL_MHZ), units="ns").start())
    dut.seg_rstn.value = 0
    dut.axil_aresetn.value = 0
    dut.link_up.value = 0
    dut.tx_rst_seg.value = 0
    dut.ctl_tx_enable.value = 0
    dut.tx_seg_ready.value = 1
    dut.loop_enable.value = 1
    dut.loop_err_inject.value = 0
    dut.loop_dat_xor.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 0
    await ClockCycles(dut.axil_aclk, 5)
    dut.axil_aresetn.value = 1
    await ClockCycles(dut.seg_clk, 8)
    dut.seg_rstn.value = 1
    await ClockCycles(dut.seg_clk, 8)
    return Axil(dut)


async def link_ready(dut):
    dut.link_up.value = 1
    dut.ctl_tx_enable.value = 1
    await ClockCycles(dut.seg_clk, 5)


async def configure(bus, length_min, length_max, mode, limit):
    await bus.write(R_CTL, CTL_CLEAR)
    await bus.write(R_CTL, 0)
    await bus.write(R_LEN_MIN, length_min)
    await bus.write(R_LEN_MAX, length_max)
    await bus.write(R_LEN_MODE, mode)
    await bus.write(R_TX_FRAME_LIMIT, limit)


async def run_until(bus, dut, want_frames, cycles=40000):
    for _ in range(cycles // 50):
        await ClockCycles(dut.seg_clk, 50)
        if int(await bus.read(R_TX_FRAMES)) >= want_frames:
            return True
    return False


async def wait_quiet(bus, dut, cycles=2000):
    await ClockCycles(dut.seg_clk, cycles)


DST_MAC = bytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
SRC_MAC = bytes([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
IP_SRC = bytes([10, 0, 0, 1])
IP_DST = bytes([10, 0, 0, 2])
UDP_SRC_PORT = 0x1234
UDP_DST_PORT = 0x5678
IP_IDENTIFICATION = 0xABCD
IP_FLAGS = 0x4000
IP_TTL = 0x40
IP_PROTOCOL = 17
IP_VERSION_IHL = 0x45
IP_DSCP = 0x00
ETHERTYPE = 0x0800


async def configure_header(bus, length):
    await bus.write(R_HDR_DST_MAC_LOW, int.from_bytes(DST_MAC[0:4], "little"))
    await bus.write(R_HDR_DST_MAC_HIGH, int.from_bytes(DST_MAC[4:6], "little"))
    await bus.write(R_HDR_SRC_MAC_LOW, int.from_bytes(SRC_MAC[0:4], "little"))
    await bus.write(R_HDR_SRC_MAC_HIGH, int.from_bytes(SRC_MAC[4:6], "little"))
    await bus.write(R_HDR_ETHERTYPE, ETHERTYPE)
    await bus.write(R_HDR_IP_VERSION_TOS, (IP_DSCP << 8) | IP_VERSION_IHL)
    await bus.write(R_HDR_IP_ID_FLAGS, (IP_FLAGS << 16) | IP_IDENTIFICATION)
    await bus.write(R_HDR_IP_TTL_PROTOCOL, (IP_PROTOCOL << 8) | IP_TTL)
    await bus.write(R_HDR_IP_SRC_ADDR, int.from_bytes(IP_SRC, "big"))
    await bus.write(R_HDR_IP_DST_ADDR, int.from_bytes(IP_DST, "big"))
    await bus.write(R_HDR_UDP_PORTS, (UDP_DST_PORT << 16) | UDP_SRC_PORT)
    await bus.write(R_HDR_CTL, HDR_CTL_ENABLE)


def expected_header(length):
    hdr = bytearray(HDR_B)
    hdr[0:6] = DST_MAC
    hdr[6:12] = SRC_MAC
    hdr[12:14] = ETHERTYPE.to_bytes(2, "big")
    hdr[14] = IP_VERSION_IHL
    hdr[15] = IP_DSCP
    hdr[16:18] = (length - 14).to_bytes(2, "big")
    hdr[18:20] = IP_IDENTIFICATION.to_bytes(2, "big")
    hdr[20:22] = IP_FLAGS.to_bytes(2, "big")
    hdr[22] = IP_TTL
    hdr[23] = IP_PROTOCOL
    hdr[24:26] = b"\x00\x00"
    hdr[26:30] = IP_SRC
    hdr[30:34] = IP_DST
    hdr[34:36] = UDP_SRC_PORT.to_bytes(2, "big")
    hdr[36:38] = UDP_DST_PORT.to_bytes(2, "big")
    hdr[38:40] = (length - 34).to_bytes(2, "big")
    hdr[40:42] = b"\x00\x00"
    return bytes(hdr)


async def collect_frames(dut, cycles):
    frames = []
    current = bytearray()
    open_frame = False
    seg_bytes = SEG_W // 8
    for _ in range(cycles):
        await RisingEdge(dut.seg_clk)
        if not (int(dut.tx_seg_valid.value) and int(dut.tx_seg_ready.value)):
            continue
        dat = int(dut.tx_seg_dat.value)
        ena = int(dut.tx_seg_ena.value)
        sop = int(dut.tx_seg_sop.value)
        eop = int(dut.tx_seg_eop.value)
        mty = int(dut.tx_seg_mty.value)
        for s in range(N_SEG):
            if not (ena >> s) & 1:
                continue
            if (sop >> s) & 1:
                current = bytearray()
                open_frame = True
            if not open_frame:
                continue
            keep = seg_bytes - (((mty >> (s * 4)) & 0xF) if (eop >> s) & 1 else 0)
            segment = (dat >> (s * SEG_W)) & ((1 << SEG_W) - 1)
            for b in range(keep):
                current.append((segment >> (b * 8)) & 0xFF)
            if (eop >> s) & 1:
                frames.append(bytes(current))
                current = bytearray()
                open_frame = False
    return frames


@cocotb.test()
async def test_header_is_inserted_and_the_payload_follows_it(dut):
    bus = await start(dut)
    await link_ready(dut)
    length = 512
    assert int(await bus.read(R_FEATURES)) & FEATURE_HDR, \
        "FEATURES does not report the header overlay"
    await configure(bus, length, length, MODE_FIXED, 0)
    await configure_header(bus, length)
    await bus.write(R_CTL, CTL_ENABLE)
    frames = await collect_frames(dut, 8000)
    await bus.write(R_CTL, 0)
    assert len(frames) >= 8, f"only {len(frames)} frame(s) were produced with the header enabled"
    want = expected_header(length)
    for n, frame in enumerate(frames):
        assert len(frame) == length, f"frame {n} is {len(frame)} bytes, expected {length}"
        got = frame[:HDR_B]
        assert got == want, (
            f"frame {n} header differs at byte "
            f"{next(i for i in range(HDR_B) if got[i] != want[i])}: "
            f"got {got.hex()} want {want.hex()}")
        first = frame[HDR_B]
        for i in range(HDR_B, len(frame)):
            expect = (first + i - HDR_B) & 0xFF
            assert frame[i] == expect, \
                f"frame {n} payload byte {i} is 0x{frame[i]:02x}, expected 0x{expect:02x}"
    dut._log.info("NIA_PKTGEN header frames=%d length=%d ip_total=%d udp_len=%d payload contiguous",
                  len(frames), length, length - 14, length - 34)


@cocotb.test()
async def test_header_disabled_leaves_the_payload_from_byte_zero(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 128, 128, MODE_FIXED, 0)
    await configure_header(bus, 128)
    await bus.write(R_HDR_CTL, 0)
    await bus.write(R_CTL, CTL_ENABLE)
    frames = await collect_frames(dut, 6000)
    await bus.write(R_CTL, 0)
    assert len(frames) >= 8, f"only {len(frames)} frame(s) were produced"
    stream = b"".join(frames)
    first = stream[0]
    for i, value in enumerate(stream):
        expect = (first + i) & 0xFF
        assert value == expect, \
            f"byte {i} of the stream is 0x{value:02x}, expected 0x{expect:02x} with the header disabled"
    assert int(await bus.read(R_RX_MISMATCH_BEATS)) == 0, \
        "the vendor checker reports a mismatch with the header disabled"
    dut._log.info("NIA_PKTGEN header disabled frames=%d stream=%d bytes contiguous",
                  len(frames), len(stream))


@cocotb.test()
async def test_identity_and_bus_check(dut):
    bus = await start(dut)
    module_type = int(await bus.read(R_MODULE_TYPE))
    assert module_type == MODULE_TYPE_VALUE, \
        f"MODULE TYPE reads 0x{module_type:08x}, expected 0x{MODULE_TYPE_VALUE:08x}"
    version = int(await bus.read(R_MAP_VERSION))
    assert (version >> 16) == MAP_VERSION_MAJOR, \
        f"MAP VERSION major is {version >> 16}, expected {MAP_VERSION_MAJOR}"
    geometry = int(await bus.read(R_SEG_GEOMETRY))
    assert (geometry >> 16) == N_SEG and (geometry & 0xFFFF) == SEG_W, \
        f"SEG_GEOMETRY {geometry:#x} does not report the geometry"
    features = int(await bus.read(R_FEATURES))
    assert features & FEATURE_HDR, \
        f"FEATURES reads 0x{features:08x} and does not report the header overlay"
    await bus.write(R_BUS_CHECK, 0xA5A5_1234)
    assert int(await bus.read(R_BUS_CHECK)) == 0xA5A5_1234, \
        "BUS_CHECK does not return a written value"


@cocotb.test()
async def test_fixed_length_loopback_is_byte_exact(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 64, 64, MODE_FIXED, 200)
    await bus.write(R_CTL, CTL_ENABLE)
    assert await run_until(bus, dut, 200), "two hundred frames were not transmitted"
    await wait_quiet(bus, dut)
    tx_frames = int(await bus.read(R_TX_FRAMES))
    tx_bytes = int(await bus.read(R_TX_BYTES))
    rx_frames = int(await bus.read(R_RX_FRAMES))
    rx_bytes = int(await bus.read(R_RX_BYTES))
    assert tx_frames >= 200, f"the limit of 200 produced only {tx_frames} frame(s)"
    assert tx_bytes == tx_frames * 64, f"TX_BYTES={tx_bytes} is not {tx_frames} frames of 64 bytes"
    assert rx_frames == tx_frames, f"the checker received {rx_frames} of {tx_frames} frame(s)"
    assert rx_bytes == tx_bytes, f"RX_BYTES={rx_bytes} does not match TX_BYTES={tx_bytes}"
    assert int(await bus.read(R_RX_MISMATCH_BEATS)) == 0, "the checker reports a payload mismatch on a clean loop"
    assert int(await bus.read(R_RX_ERR_FRAMES)) == 0, "the checker reports an error frame on a clean loop"
    status = int(await bus.read(R_STATUS))
    assert status & ST_DONE, f"DONE is not set after the limit, STATUS reads 0x{status:08x}"
    assert status & ST_LOCKED, f"the checker did not lock, STATUS reads 0x{status:08x}"
    assert not (status & ST_UNDERFLOW), "the client bus underflowed"
    assert not (status & ST_OVERFLOW), "the generator overflowed its buffer"
    dut._log.info("NIA_PKTGEN loopback fixed 64 B tx_frames=%d rx_frames=%d bytes=%d mismatch=0",
                  tx_frames, rx_frames, tx_bytes)


@cocotb.test()
async def test_random_length_loopback_is_byte_exact(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, LEN_MIN_HW, LEN_MAX_HW, MODE_RAND, 300)
    await bus.write(R_CTL, CTL_ENABLE)
    assert await run_until(bus, dut, 300), "three hundred frames were not transmitted"
    await wait_quiet(bus, dut)
    tx_frames = int(await bus.read(R_TX_FRAMES))
    tx_bytes = int(await bus.read(R_TX_BYTES))
    rx_frames = int(await bus.read(R_RX_FRAMES))
    rx_bytes = int(await bus.read(R_RX_BYTES))
    assert rx_frames == tx_frames, f"the checker received {rx_frames} of {tx_frames} frame(s)"
    assert rx_bytes == tx_bytes, f"RX_BYTES={rx_bytes} does not match TX_BYTES={tx_bytes}"
    assert int(await bus.read(R_RX_MISMATCH_BEATS)) == 0, "a random length stream mismatched over a clean loop"
    mean = tx_bytes / max(tx_frames, 1)
    assert LEN_MIN_HW <= mean <= LEN_MAX_HW, \
        f"the mean frame is {mean:.1f} bytes, outside {LEN_MIN_HW} to {LEN_MAX_HW}"
    dut._log.info("NIA_PKTGEN loopback random frames=%d bytes=%d mean=%.1f B mismatch=0",
                  tx_frames, tx_bytes, mean)


@cocotb.test()
async def test_corrupted_payload_is_counted(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 64, 64, MODE_FIXED, 0)
    await bus.write(R_CTL, CTL_ENABLE)
    await ClockCycles(dut.seg_clk, 400)
    status = int(await bus.read(R_STATUS))
    assert status & ST_LOCKED, f"the checker did not lock on a clean loop, STATUS reads 0x{status:08x}"
    assert int(await bus.read(R_RX_MISMATCH_BEATS)) == 0, "a clean loop reported a mismatch"
    dut.loop_dat_xor.value = 1 << (8 * (BEAT_B - 1))
    await ClockCycles(dut.seg_clk, 8)
    dut.loop_dat_xor.value = 0
    await ClockCycles(dut.seg_clk, 400)
    await bus.write(R_CTL, 0)
    mismatch = int(await bus.read(R_RX_MISMATCH_BEATS))
    assert mismatch >= 1, "a corrupted payload was not counted"
    dut._log.info("NIA_PKTGEN corruption counted mismatch=%d", mismatch)


@cocotb.test()
async def test_error_frame_is_counted(dut):
    bus = await start(dut)
    await link_ready(dut)
    dut.loop_err_inject.value = 1
    await configure(bus, 64, 64, MODE_FIXED, 200)
    await bus.write(R_CTL, CTL_ENABLE)
    assert await run_until(bus, dut, 200), "the generator did not transmit"
    await wait_quiet(bus, dut)
    assert int(await bus.read(R_RX_ERR_FRAMES)) >= 1, "an error frame was not counted"


@cocotb.test()
async def test_valid_is_contiguous_within_a_frame(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 4 * BEAT_B, 4 * BEAT_B, MODE_FIXED, 64)

    breaks = []

    async def watch_valid():
        in_frame = False
        while True:
            await FallingEdge(dut.seg_clk)
            valid = bool(dut.tx_seg_valid.value) and int(dut.tx_seg_ena.value) != 0
            ready = bool(dut.tx_seg_ready.value)
            eop = int(dut.tx_seg_eop.value & dut.tx_seg_ena.value) != 0
            if in_frame and not valid:
                breaks.append(get_sim_time("ns"))
                in_frame = False
            elif valid and ready:
                in_frame = not eop

    watcher = cocotb.start_soon(watch_valid())
    await bus.write(R_CTL, CTL_ENABLE)
    reached = await run_until(bus, dut, 64)
    watcher.kill()
    assert reached, "the generator did not transmit sixty four frames"
    assert not breaks, (
        f"tx_seg_valid deasserted inside a frame at {breaks[:4]} ns, which PG369 p120 forbids")


@cocotb.test()
async def test_stall_detector_latches(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 8 * BEAT_B, 8 * BEAT_B, MODE_FIXED, 0)
    await bus.write(R_CTL, CTL_ENABLE)
    await ClockCycles(dut.seg_clk, 200)
    dut.tx_seg_ready.value = 0
    await ClockCycles(dut.seg_clk, STALL_CYC + 60)
    status = int(await bus.read(R_STATUS))
    assert status & ST_STALL, "the stall detector did not latch while ready was held low"
    assert int(await bus.read(R_STALL_CYCLE)) != 0, "the stall timestamp is zero"
    before = int(await bus.read(R_TX_FRAMES))
    dut.tx_seg_ready.value = 1
    await ClockCycles(dut.seg_clk, 400)
    assert int(await bus.read(R_TX_FRAMES)) > before, "the generator did not resume after the stall"


@cocotb.test()
async def test_link_down_starts_no_new_frame(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 64, 64, MODE_FIXED, 0)
    await bus.write(R_CTL, CTL_ENABLE)
    await ClockCycles(dut.seg_clk, 400)
    before = int(await bus.read(R_TX_FRAMES))
    assert before > 0, "the generator did not start with the link up"
    dut.link_up.value = 0
    dut.ctl_tx_enable.value = 0
    await ClockCycles(dut.seg_clk, 600)
    settled = int(await bus.read(R_TX_FRAMES))
    await ClockCycles(dut.seg_clk, 600)
    assert int(await bus.read(R_TX_FRAMES)) == settled, "a frame started with the link down"
    await link_ready(dut)
    await ClockCycles(dut.seg_clk, 600)
    assert int(await bus.read(R_TX_FRAMES)) > settled, "the generator did not resume when the link returned"


@cocotb.test()
async def test_clear_zeroes_the_counters(dut):
    bus = await start(dut)
    await link_ready(dut)
    await configure(bus, 64, 64, MODE_FIXED, 100)
    await bus.write(R_CTL, CTL_ENABLE)
    assert await run_until(bus, dut, 100), "the generator did not transmit"
    await wait_quiet(bus, dut, 400)
    await bus.write(R_CTL, CTL_CLEAR)
    await ClockCycles(dut.seg_clk, 40)
    await Timer(200, units="ns")
    assert int(await bus.read(R_TX_FRAMES)) == 0, "CLEAR did not zero TX_FRAMES"
    assert int(await bus.read(R_RX_FRAMES)) == 0, "CLEAR did not zero RX_FRAMES"
    assert int(await bus.read(R_LATCHED_TX_FRAMES)) != 0, "the latched frame counter did not publish on clear"


@cocotb.test()
async def test_frame_rate_table(dut):
    bus = await start(dut)
    await link_ready(dut)
    lengths = [LEN_MIN_HW, LEN_MIN_HW + 1, 64, 65, 512, 1518]
    if LEN_MAX_HW not in lengths:
        lengths.append(LEN_MAX_HW)
    rows = []
    for length in lengths:
        await configure(bus, length, length, MODE_FIXED, 0)
        state = {"cycles": 0, "segments": 0, "pending": 0, "frames": 0, "idle": 0}

        async def monitor():
            while True:
                await FallingEdge(dut.seg_clk)
                valid = bool(dut.tx_seg_valid.value)
                ready = bool(dut.tx_seg_ready.value)
                ena = int(dut.tx_seg_ena.value)
                eop = int(dut.tx_seg_eop.value) & ena
                sop = int(dut.tx_seg_sop.value) & ena
                if state["cycles"] > 0 or (valid and ready and ena):
                    state["cycles"] += 1
                    if not (valid and ready and ena):
                        state["idle"] += 1
                if valid and ready:
                    for s in range(N_SEG):
                        if not (ena >> s) & 1:
                            continue
                        if (sop >> s) & 1:
                            state["pending"] = 0
                        state["pending"] += 1
                        if (eop >> s) & 1:
                            state["segments"] += state["pending"]
                            state["frames"] += 1
                            state["pending"] = 0

        watcher = cocotb.start_soon(monitor())
        await bus.write(R_CTL, CTL_ENABLE)
        await ClockCycles(dut.seg_clk, 4000)
        await bus.write(R_CTL, 0)
        watcher.kill()
        await ClockCycles(dut.seg_clk, 200)

        frames = state["frames"]
        assert frames > 4, f"length {length}: only {frames} frame(s) in the window"
        segs_per_frame = state["segments"] / frames
        want = (length + SEG_B - 1) // SEG_B
        fps = SEG_MHZ * 1e6 * N_SEG / segs_per_frame
        wire = fps * (length + 20) * 8 / 1e9
        rows.append((length, segs_per_frame, want, fps / 1e6, wire, state["idle"], state["cycles"]))
        await bus.write(R_CTL, CTL_CLEAR)
        await bus.write(R_CTL, 0)

    for length, segs, want, mfps, wire, idle, cycles in rows:
        dut._log.info("NIA_RATE len=%d segments_per_frame=%.2f expected=%d frames_per_s=%.1fM wire=%.1f Gb/s idle=%d of %d",
                      length, segs, want, mfps, wire, idle, cycles)
    for length, segs, want, mfps, wire, idle, cycles in rows:
        assert abs(segs - want) < 0.05, f"length {length}: {segs:.2f} segments per frame, expected {want}"
        assert idle * 100 <= cycles, f"length {length}: {idle} idle cycle(s) of {cycles}"
