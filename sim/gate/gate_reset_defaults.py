#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_reset_defaults.py
# Description : Checks the reset defaults of the data path reset requests, which must be
#               inactive out of reset.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "gt_rst_req_gate.sv"))
MAC = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "dcmac_mac_group.sv"))

TX_CLK_MHZ = 250.0
FREERUN_MHZ = 100.0
PG442_RESET_MS = 150.0
PG442_WAIT_CLOCKS = 8

fails = []
checks = 0

def check(cond, msg):
    global checks
    checks += 1
    if not cond:
        fails.append(msg)
    print("  %-4s %s" % ("ok" if cond else "FAIL", msg))

def param(src, name):
    m = re.search(r"parameter\s+(?:int|integer)\s+%s\s*=\s*([0-9_]+)" % name, src)
    return int(m.group(1).replace("_", "")) if m else None

def main():
    gate = open(GATE).read()
    mac = open(MAC).read()

    print("===: the SHIPPED defaults of gt_rst_req_gate ===")
    pulse = param(gate, "PULSE_CYC")
    settle = param(gate, "SETTLE_CYC")
    tmo = param(gate, "DONE_TMO_CYC")
    en = param(gate, "EN_GATE")
    check(pulse == 64, "PULSE_CYC default is 64 (got %s)" % pulse)
    check(settle == 250000, "SETTLE_CYC default is 250000 = 1 ms @ %.0f MHz (got %s)"
          % (TX_CLK_MHZ, settle))
    check(tmo == 50000000, "DONE_TMO_CYC default is 50000000 (got %s)" % tmo)
    check(en == 1, "EN_GATE default is 1 - the gate is ON with no define  (got %s)" % en)

    if pulse:
        pulse_ns = pulse / TX_CLK_MHZ * 1000.0
        need_ns = PG442_WAIT_CLOCKS / FREERUN_MHZ * 1000.0
        check(pulse_ns >= need_ns,
              "PULSE_CYC = %.0f ns >= PG442 p.14's %d free-run clocks = %.0f ns"
              % (pulse_ns, PG442_WAIT_CLOCKS, need_ns))
    if tmo:
        tmo_ms = tmo / (TX_CLK_MHZ * 1e6) * 1e3
        check(tmo_ms > PG442_RESET_MS,
              "DONE_TMO_CYC = %.0f ms > PG442 p.15's %.0f ms worst-case reset"
              % (tmo_ms, PG442_RESET_MS))
    if tmo and settle:
        check(tmo > settle, "DONE_TMO_CYC > SETTLE_CYC (%d > %d)" % (tmo, settle))

    print("\n===: the one-shot is edge-triggered AND variant-latched (both halves present) ===")
    check("wire req_rise  = req_level & ~req_1d;" in gate,
          "the request is EDGE-detected, not level-passed")
    check("if (!req_level) arm_r <= 1'b1;" in gate,
          "re-arm requires the host level to return to 0")
    check("assign req_pulse      = (EN_GATE != 0) ? pulse_r : req_level;" in gate,
          "EN_GATE = 0 is a raw pass-through - the negative control exists")

    print("\n===: the interlock carries BOTH done and busy ===")
    check("wire allow     = done_q & ~seq_busy & ~stuck_r;" in gate,
          "allow = gt_reset_done AND !seq_busy AND !stuck (PG442 p.15/p.16)")

    print("\n===  / integration: dcmac_mac_group ===")
    n_inst = len(re.findall(r"gt_rst_req_gate\s+#\(", mac))
    check(n_inst == 2, "exactly 2 gate instances in the per-client generate (RX + TX) (got %d)"
          % n_inst)
    check(".req_level      (ctl_rx_datapath_reset_req[q])" in mac
          and ".req_level      (ctl_tx_datapath_reset_req[q])" in mac,
          "each instance takes its OWN direction's host request (never shared)")
    check(".host_link_reset_req         (host_rx_dp_req_gated)" in mac
          and "p_rx_dp_reset | seq_rx_dp_for_client" in mac,
          "the HOST term reaches the state machine through the gate and the SEQUENCER's term "
          "reaches the PHY unmediated")
    check("assign p_tx_dp_reset       = host_tx_dp_req_gated;" in mac,
          "the TX host term is gated too")
    check("ctl_rx_datapath_reset_req[c] | seq_rx_dp_for_client[c]" not in mac,
          "the OLD ungated OR is gone (a leftover would be a second, unbounded path)")
    for p in ("EN_DPRST_GATE", "DPRST_PULSE_CYC", "DPRST_SETTLE_CYC", "DPRST_DONE_TMO_CYC"):
        check(("parameter integer %s" % p) in mac,
              "%s is a parameter of the seam wrapper (: reachable from above)" % p)
    check(param(mac, "EN_DPRST_GATE") == 1,
          "the wrapper's EN_DPRST_GATE default is 1, so every image gets the gate")

    print("\n%d checks, %d failed" % (checks, len(fails)))
    if fails:
        for f in fails:
            print("   %s" % f)
        print("DPRST_DEFAULTS_GATE=FAIL")
        return 1
    print("DPRST_DEFAULTS_GATE=PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
