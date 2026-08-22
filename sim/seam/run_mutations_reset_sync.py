#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_mutations_reset_sync.py
# Description : The mutation gate of the dual port reset synchroniser check.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import argparse
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
GATE = os.path.join(HERE, "..", "gate", "gate_dual_port_reset_sync.py")
PHY = os.path.join(RTL, "dcmac_phy_wrapper.sv")

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

MUTANTS = [
    dict(
        id="R27M1", check="P3", file=PHY,
        anchor="      .clk (axis_clk), .din (tx_datapath_reset), .dout (tx_dp_reset_s));",
        replace="      .clk (axis_clk), .din (tx_datapath_reset | rx_datapath_reset), "
                ".dout (tx_dp_reset_s));",
        why=" **ORs RX INTO TX** at the synchroniser input, so every RX-only re-align escalation "
  "also asserts the TX datapath reset.: RX and TX shall be on separate paths that "
  "are NEVER ORed.  measured what RX-only is worth: cross-cage dual-200G went from "
            "**6/10 to 15/15**.",
    ),
    dict(
        id="R27M2", check="P3/P4", file=PHY,
        anchor="    .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[0]),",
        replace="    .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[0] | "
                "rx_dp_reset_stretched[0]),",
        why=" **THE VENDOR EXDES DEFECT, INJECTED INTO OUR OWN RTL.** The GT's TX datapath-reset "
            "pin is driven by the OR of the TX and RX levels - i.e. one shared bit, which is "
            "literally what the vendor exdes did (RX port dangling, both resets off the TX bit). A "
            "reset on one board then drops its own TX and un-aligns the partner: a 200G/400G "
            "intermittency that looked exactly like silicon and cost a hardware campaign "
  ".  This is the mutant 's test column names, and after "
            "it that root cause has a regression test in OUR tree.",
    ),
    dict(
        id="R27M3", check="P2", file=PHY,
        anchor="    dcmac_sync2 #(.WIDTH(N_CLIENT), .STAGES(2), .INIT('0)) u_sync_rx_dp (",
        replace="    dcmac_sync2 #(.WIDTH(N_CLIENT), .STAGES(1), .INIT('0)) u_sync_rx_dp (",
  why="The RX datapath-reset synchroniser collapses to ONE stage, i.e.  half-applied. "
            " NO SIMULATION CAN SEE THIS: the stub PHY has one clock (L1) and an ideal clock "
  "model captures a single flop happily. It shows up in the BUILD, which is where  "
            "showed up as 213 of 213 failing setup endpoints.",
    ),
    dict(
        id="R27M4", check="P4", file=PHY,
        anchor="      .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[1]),",
        replace="      .INTF0_rst_tx_datapath_in         (tx_dp_reset_s[0]),",
        why=" Quad 1's TX datapath reset is driven from CLIENT 0's level - a cross-client reset "
  "with the whole structure left intact, which is 's failure arriving through the "
  "PHY instead of through the sequencer (the route  took). The clause asks "
            "for the per-quad == per-client equivalence to be ASSERTED rather than assumed; this "
            "mutant is what makes that assertion mean something.",
    ),
    dict(
        id="R27M5", check="P1", file=PHY,
        anchor="  if (EN_DPRST_SYNC != 0) begin : g_dprst_sync",
        replace="  if (1) begin : g_dprst_sync",
        why="The NEGATIVE CONTROL is removed: `EN_DPRST_SYNC = 0` no longer reproduces the pre-N6 "
  "structure, so the claim ' changed timing, not function' becomes unfalsifiable at "
            "every level.  A clause whose control has been deleted is indistinguishable from a "
  "clause nobody checked - which is what audit  found for.",
    ),
]

def md5(p):
    with open(p, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def run_gate():
    r = subprocess.run([sys.executable, GATE], capture_output=True, text=True)
    last = ""
    for ln in r.stdout.strip().splitlines():
        if ln.startswith("TOTAL "):
            last = ln
    return r.returncode, last or "(no TOTAL line)"

def preflight():
    bad = 0
    text = open(PHY).read()
    for m in MUTANTS:
        n = text.count(m["anchor"])
        print("%s %-6s anchor x%d  [%s]" % ("OK " if n == 1 else "BAD", m["id"], n, m["check"]))
        if n != 1:
            bad += 1
    print("TOTAL %d BAD %d" % (len(MUTANTS), bad))
    return bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preflight", action="store_true")
    a = ap.parse_args()

    print("TARGET  %s" % PHY)
    print(" REAL RTL, not a fixture. This stage mutates and restores; it does not own this file.")
    before = md5(PHY)
    print("MD5     before %s" % before)

    print("\n=== anchor pre-flight ===")
    if preflight():
        print("MUTATION RESULT: FAIL (stale anchors - fix the catalogue first)")
        return 1
    if a.preflight:
        return 0

    print("\n=== base gate on the unmutated RTL ===")
    rc, last = run_gate()
    print("BASE    gate exit=%d  %s" % (rc, last))
    if rc != 0:
        print("MUTATION RESULT: FAIL (the conformant RTL does not pass its own gate)")
        return 1

    original = open(PHY).read()
    caught, rows = 0, []
    with rtl_lock(nia_rtl_root(__file__), who="run_mutations_reset_sync.py"):
        try:
            for m in MUTANTS:
                open(PHY, "w").write(original.replace(m["anchor"], m["replace"], 1))
                rc, last = run_gate()
                verdict = "CAUGHT" if rc != 0 else "NOT CAUGHT"
                caught += 1 if rc != 0 else 0
                rows.append((m["id"], m["check"], m["why"], verdict))
                print("MUT     %-6s [%-5s] gate exit=%d  %-10s %s"
                      % (m["id"], m["check"], rc, verdict, last))
                open(PHY, "w").write(original)
        finally:
            open(PHY, "w").write(original)

    after = md5(PHY)
    print("MD5     after  %s  %s"
          % (after, "restored" if after == before else " NOT RESTORED"))

    print("\n| mutant | gate check | injected defect | verdict |")
    print("|---|---|---|---|")
    for mid, chk, why, verdict in rows:
        print("| %s | %s | %s | %s |" % (mid, chk, why, verdict))

    ok = caught == len(MUTANTS) and after == before
    print("MUTATION RESULT: %s (%d/%d caught against the REAL PHY, md5 %s)"
          % ("PASS" if ok else "FAIL", caught, len(MUTANTS),
             "restored" if after == before else " NOT RESTORED"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
