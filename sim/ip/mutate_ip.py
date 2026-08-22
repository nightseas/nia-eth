#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : mutate_ip.py
# Description : The mutation gate of the generated IP checks: it mutates an anchor in a
#               generated file and requires the check that guards it to fail.
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

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

MUTANTS = [
    ("IPM1", "../ip/dcmac_fifo_ip.tcl",
     "    CONFIG.FIFO_MODE                2 \\",
     "    CONFIG.FIFO_MODE                1 \\",
     " THE REPLACEMENT FOR M6. Store-and-forward defeated by CONFIGURATION: the TX frame "
     "FIFO becomes a plain FIFO, so a bubble on its write side becomes a mid-frame "
     "tx_seg_valid drop on its read side - exactly what  forbids (PG369 p118/p120). In the "
     "IP variant part of the design IS the IP configuration, so that is where the mutant belongs.",
     "TEST 1 w7_gapless_with_bubbles"),

    ("IPM2", "fifo_ip/tx_frame_fifo.sv",
     "    assign m_axis_tuser = m_axis_tlast ? (abort_acc | ip_tuser[0]) : 1'b0;",
     "    assign m_axis_tuser = ip_tuser[0];",
  ": the frame-scoped collapse reverted to BEAT-SCOPED - the same defect M8 "
     "reproduces on RX, on the TX side of the IP variant. An abort flagged on an interior beat "
     "is then presented on that beat, where dcmac_seg_axis_tx (`err = tuser & eop_s`) drops "
     "it and the frame reaches the wire with a GOOD FCS. MUST fail ONLY the mid-frame test: "
     "the last-beat case still works, and that localisation is the point.",
     "TEST 3 ns8a_abort_mid_frame"),

    ("IPM3", "fifo_ip/tx_frame_fifo.sv",
     "    else if (xfer)                  abort_acc <= abort_acc | ip_tuser[0];",
     "    else if (xfer)                  abort_acc <= abort_acc;",
  " by a different mechanism from IPM2: the accumulator stops accumulating while the "
     "emit stays correct. Two mutants for one clause on purpose - the latch and the emit are "
     "separate, and a suite that catches only one of them is only half a gate.",
     "TEST 3 ns8a_abort_mid_frame"),

    ("IPM4", "fifo_ip/tx_frame_fifo.sv",
     "                           m_axis_tlast ? (abort_acc | ip_tuser[0]) : 1'b0};",
     "                           (abort_acc | ip_tuser[0])};",
  "The 'and 0 on every earlier beat' half of, in the USER_W>1 branch: the abort is "
     "emitted on EVERY beat of the frame, so `err` appears on non-EOP segments. Scored by the "
     "monitor's `err_misplaced` counter.  This branch is only reachable with TX_TAG_W>0, "
  "which the IP variant refuses  - so it is expected to be reported as NOT APPLICABLE "
     "in the default variant, and it is kept so the guard is not silently lost if a tag variant is "
     "ever generated.",
     "TEST 3 ns8a_abort_mid_frame (tag variant only)"),

    ("IPM5", "fifo_ip/eth_axis_async_fifo.sv",
     "    else if (s_axis_tvalid && !s_axis_tready) ovf_r <= 1'b1;",
     "    else if (s_axis_tvalid && !s_axis_tready) ovf_r <= 1'b0;",
  ": the reproduced sticky `overflow` defeated. `axis_data_fifo` has no overflow "
  "output, so this flop IS the  status bit `rx_overflow` in the IP variant; losing it "
  "would silently blank a bit the host reads through the / CSR window.",
     "TEST 5 ns7_whole_frame_drop_slow_rxclk"),

    ("IPM6", "dcmac_axis_frame_fifo.sv",
     "  wire frame_err = s_axis_tuser[0] | err_seen;",
     "  wire frame_err = s_axis_tuser[0];",
  " M8, CARRIED. The RX frame FIFO is ours in BOTH variants, so 's frame-scoped "
     "flag must be re-scored here: an error flagged before the final AXIS beat never reaches "
     "the tlast beat, so the NIC core never learns the frame was bad.",
     "TEST 4 ns4_rx_err_flagged_and_forwarded"),

    ("IPM7", "dcmac_axis_frame_fifo.sv",
     "          if (full)          drop_frame <= 1'b1;",
     "          if (full)          drop_frame <= 1'b0;",
  " M10, CARRIED.  defeated: beats are skipped mid-frame and the frame is committed "
     "TRUNCATED, so a partial frame reaches the core and can fuse onto the next one. Now "
     "back-pressured by the IP CDC rather than by our model, which is the reason to re-score "
     "it rather than cite the model variant.",
     "TEST 5 ns7_whole_frame_drop_slow_rxclk"),
]

def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def preflight():
    bad = 0
    for mid, rel, anchor, _rep, _why, _test in MUTANTS:
        path = os.path.join(RTL, rel)
        if not os.path.exists(path):
            print(f"BAD  missing file      {mid}  {rel}")
            bad += 1
            continue
        n = open(path).read().count(anchor)
        if n != 1:
            print(f"BAD  anchor x{n}        {mid}  {rel}")
            bad += 1
        else:
            print(f"OK   anchor x1         {mid}  {rel}")
    print(f"TOTAL {len(MUTANTS)} BAD {bad}")
    return bad

def listing():
    for mid, rel, _a, _r, why, test in MUTANTS:
        print(f"{mid}  {rel}")
        print(f"      must fail: {test}")
        print(f"      why:       {' '.join(why.split())}")

def score(vivado, work):
    script = os.path.join(HERE, "run_xsim_ip.tcl")

    def run():
        log = subprocess.run([vivado, "-mode", "batch", "-source", script,
                              "-tclargs", work], capture_output=True, text=True).stdout
        verdict = "NO_VERDICT"
        for ln in log.splitlines():
            if ln.startswith("TB_RESULT"):
                verdict = ln.strip()
        return verdict

    base = run()
    print(f"BASE  {base}")
    if not base.startswith("TB_RESULT PASS"):
        print("MUTATION RESULT: FAIL (the baseline variant is already red; fix that first)")
        return 1

    caught = 0
    with rtl_lock(nia_rtl_root(__file__), who="mutate_ip.py score"):
      for mid, rel, anchor, rep, _why, test in MUTANTS:
        path = os.path.join(RTL, rel)
        original = open(path).read()
        before = md5(path)
        try:
            open(path, "w").write(original.replace(anchor, rep))
            v = run()
        finally:
            open(path, "w").write(original)
        assert md5(path) == before, f"{mid}: {rel} was NOT restored"
        ok = v.startswith("TB_RESULT FAIL")
        caught += ok
        print(f"MUT   {mid:5s} {'CAUGHT    ' if ok else 'NOT CAUGHT'} expected={test}  {v}")

    print(f"MUTATION RESULT: {'PASS' if caught == len(MUTANTS) else 'FAIL'} "
          f"({caught}/{len(MUTANTS)} caught)")
    return 0 if caught == len(MUTANTS) else 1

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--preflight", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--run", nargs=2, metavar=("VIVADO", "WORK"))
    a = ap.parse_args()
    if a.list:
        listing()
        sys.exit(0)
    if a.run:
        sys.exit(score(a.run[0], a.run[1]))
    sys.exit(1 if preflight() else 0)
