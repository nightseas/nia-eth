# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from test_dcmac_pktgen import (
    MAP_VERSION_MAJOR,
    MODULE_TYPE_VALUE,
    R_BUS_CHECK,
    R_MAP_VERSION,
    R_MODULE_TYPE,
)

N_CLIENT = 2
AXIL_AW = int(os.environ.get("PKTGEN_AXIL_AW", "12"))
REF_CLK_NS = int(os.environ.get("REF_CLK_NS", "4"))


class DualSeamAxil:
    def __init__(self, dut, client):
        self.dut = dut
        self.client = client
        self.sel = 1 << client

    def _addr(self, addr):
        return addr << (AXIL_AW * self.client)

    async def write(self, addr, value):
        d = self.dut
        d.pg_awaddr.value = self._addr(addr)
        d.pg_awvalid.value = self.sel
        d.pg_wdata.value = (value << (32 * self.client))
        d.pg_wstrb.value = (0xF << (4 * self.client))
        d.pg_wvalid.value = self.sel
        d.pg_bready.value = self.sel
        for _ in range(400):
            await RisingEdge(d.usr_clk)
            if int(d.pg_bvalid.value) & self.sel:
                d.pg_awvalid.value = 0
                d.pg_wvalid.value = 0
                await ClockCycles(d.usr_clk, 2)
                d.pg_bready.value = 0
                return
        raise AssertionError(
            f"client {self.client} write to 0x{addr:03x} did not complete: "
            f"awready={int(d.pg_awready.value)} wready={int(d.pg_wready.value)} "
            f"bvalid={int(d.pg_bvalid.value)} usr_rstn={int(d.usr_rstn.value)}")

    async def read(self, addr):
        d = self.dut
        d.pg_araddr.value = self._addr(addr)
        d.pg_arvalid.value = self.sel
        d.pg_rready.value = self.sel
        for _ in range(400):
            await RisingEdge(d.usr_clk)
            if int(d.pg_rvalid.value) & self.sel:
                value = (int(d.pg_rdata.value) >> (32 * self.client)) & 0xFFFFFFFF
                d.pg_arvalid.value = 0
                await ClockCycles(d.usr_clk, 1)
                d.pg_rready.value = 0
                return value
        raise AssertionError(
            f"client {self.client} read from 0x{addr:03x} did not complete: "
            f"arready={int(d.pg_arready.value)} rvalid={int(d.pg_rvalid.value)} "
            f"usr_rstn={int(d.usr_rstn.value)} link_up=0x{int(d.link_up.value):x}")


async def bring_up(dut):
    dut.sys_reset.value = 1
    dut.gt_ref_clk0_n.value = 1
    dut.gt_ref_clk1_n.value = 1
    cocotb.start_soon(Clock(dut.gt_ref_clk0_p, REF_CLK_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.gt_ref_clk1_p, REF_CLK_NS, units="ns").start())
    dut.gt_rxp_in.value = 0
    dut.gt_rxn_in.value = 0
    dut.ctl_bringup_restart_req.value = 0
    dut.ctl_stats_req.value = 0
    dut.ctl_rx_force_resync_req.value = 0
    dut.ctl_rx_datapath_reset_req.value = 0
    dut.ctl_tx_datapath_reset_req.value = 0
    dut.ctl_stat_rd_idx.value = 0
    dut.pg_awvalid.value = 0
    dut.pg_wvalid.value = 0
    dut.pg_bready.value = 0
    dut.pg_arvalid.value = 0
    dut.pg_rready.value = 0
    await ClockCycles(dut.usr_clk, 20)
    dut.sys_reset.value = 0
    await ClockCycles(dut.usr_clk, 50)
    return [DualSeamAxil(dut, c) for c in range(N_CLIENT)]


async def wait_link(dut, mask, cycles=40000):
    for _ in range(cycles):
        await RisingEdge(dut.seg_clk)
        if (int(dut.link_up.value) & mask) == mask:
            return True
    return False


@cocotb.test()
async def test_every_client_window_answers_and_is_distinct(dut):
    bus = await bring_up(dut)
    for client, axil in enumerate(bus):
        assert int(await axil.read(R_MODULE_TYPE)) == MODULE_TYPE_VALUE, (
            f"client {client} did not identify itself")
        version = int(await axil.read(R_MAP_VERSION))
        assert (version >> 16) == MAP_VERSION_MAJOR, f"client {client} map version {version:#x}"
    patterns = [0xA5A50000 | c for c in range(N_CLIENT)]
    for client, axil in enumerate(bus):
        await axil.write(R_BUS_CHECK, patterns[client])
    for client, axil in enumerate(bus):
        read = int(await axil.read(R_BUS_CHECK))
        assert read == patterns[client], (
            f"client {client} returned {read:#010x} for {patterns[client]:#010x}, so the two "
            "windows alias and this is one instance rather than two")


@cocotb.test()
async def test_both_groups_reach_transfer(dut):
    await bring_up(dut)
    up = await wait_link(dut, (1 << N_CLIENT) - 1)
    assert up, (
        f"link_up reached 0x{int(dut.link_up.value):x} of 0x{(1 << N_CLIENT) - 1:x}, "
        f"mac_fsm_state 0x{int(dut.mac_fsm_state.value):x}")


@cocotb.test()
async def test_a_repair_on_one_client_leaves_the_other_up(dut):
    await bring_up(dut)
    assert await wait_link(dut, (1 << N_CLIENT) - 1), "both groups never came up"

    dut.ctl_rx_datapath_reset_req.value = 0b01
    await ClockCycles(dut.usr_clk, 4)
    dut.ctl_rx_datapath_reset_req.value = 0

    sibling_low = 0
    victim_fell = 0
    for _ in range(20000):
        await RisingEdge(dut.seg_clk)
        up = int(dut.link_up.value)
        if not (up & 0b10):
            sibling_low += 1
        if not (up & 0b01):
            victim_fell = 1
    assert victim_fell, "the repair request reached no reset, so this test proves nothing"
    assert sibling_low == 0, (
        f"client 1 lost link_up for {sibling_low} cycles while client 0 was repaired, so the "
        "reset scope is larger than the fault it responds to")


@cocotb.test()
async def test_the_repaired_client_returns(dut):
    await bring_up(dut)
    assert await wait_link(dut, (1 << N_CLIENT) - 1), "both groups never came up"
    dut.ctl_rx_datapath_reset_req.value = 0b01
    await ClockCycles(dut.usr_clk, 4)
    dut.ctl_rx_datapath_reset_req.value = 0
    assert await wait_link(dut, (1 << N_CLIENT) - 1), (
        "client 0 did not return after its own repair, which is a state from which recovery is "
        "impossible")
