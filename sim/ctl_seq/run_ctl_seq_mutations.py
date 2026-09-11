#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_ctl_seq_mutations.py
# Description : The mutation gate of the sequencer: it records the digest before and after
#               each mutant, requires the named test to fail, and requires the unmutated
#               tree to pass first.
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
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_ctl_seq.sv"))
GATE = os.path.join(HERE, "..", "gate", "gate_ctl_seq_waits.py")

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

LOCK_DIR_PROTECTED = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))

FIXED_B5W = ("      else if (pc == P_B5W) begin op = OP_WAIT; "
             "w = (32'(T_STEP2_MS) * 32'(CYC_PER_MS)); end")
DEFECT_B5W = "      else if (pc == P_B5W) begin op = OP_WAIT; w = 16'(T_STEP2_MS); end"

FIXED_B10 = ("      else if (pc == P_B10 + 1) begin op = OP_WAIT; "
             "w = (32'(T_PORT_CHAN_GAP_MS) * 32'(CYC_PER_MS)); end")

MUTANTS = [
    dict(
        name="G1M1_b5w_unscaled",
  why=("  VERBATIM. Restores the exact shipped line: the B5 post-STEP2 "
             "settle loses its `* CYC_PER_MS`, so 10 ms becomes 10 cycles = 40 ns at "
  "250 MHz, a 250 000x shortfall that reached silicon."),
        anchor=FIXED_B5W,
        replace=DEFECT_B5W,
    ),
    dict(
        name="G1M2_b5w_deleted",
        why=("The other half of the class: the delay is not unscaled but DELETED (the "
             "record becomes a 0-cycle wait). Caught by MIN_WAIT_RECORDS, which is why "
             "the gate counts records instead of only pattern-matching them."),
        anchor=FIXED_B5W,
        replace="      else if (pc == P_B5W) begin op = OP_WAIT; w = 32'd0; end",
    ),
    dict(
        name="G1M3_b10_unscaled",
        why=("Proves the gate is GENERAL, not hardcoded to B5W: it unscales a DIFFERENT "
             "record - B10's 50 ms port/channel gap, which both references use and which "
  "had already been dropped once (gap (b))."),
        anchor=FIXED_B10,
        replace=("      else if (pc == P_B10 + 1) begin op = OP_WAIT; "
                 "w = 32'(T_PORT_CHAN_GAP_MS); end"),
    ),
]

def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def preflight(text):
    bad = 0
    for m in MUTANTS:
        n = text.count(m["anchor"])
        status = "OK " if n == 1 else "BAD"
        if n != 1:
            bad += 1
        print(f"{status} anchor x{n}  {m['name']}")
    print(f"TOTAL {len(MUTANTS)} BAD {bad}")
    return bad

def run_gate():
    r = subprocess.run([sys.executable, GATE, SRC], capture_output=True, text=True)
    return r.returncode, r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preflight", action="store_true")
    args = ap.parse_args()

    original = open(SRC).read()
    md5_before = md5(SRC)
    print(f"SRC   {SRC}")
    print(f"MD5   before {md5_before}")

    bad = preflight(original)
    if bad:
        print("MUTATION RESULT: FAIL (stale anchors - fix the catalogue first)")
        return 1
    if args.preflight:
        return 0

    rc, last = run_gate()
    print(f"BASE  gate exit={rc}  {last}")
    if rc != 0:
        print("MUTATION RESULT: FAIL (the baseline is already red; fix that first)")
        return 1

    caught = 0
    with rtl_lock(nia_rtl_root(__file__), who="run_ctl_seq_mutations.py"):
      try:
        for m in MUTANTS:
            open(SRC, "w").write(original.replace(m["anchor"], m["replace"]))
            rc, last = run_gate()
            verdict = "CAUGHT" if rc != 0 else "NOT CAUGHT"
            if rc != 0:
                caught += 1
            print(f"MUT   {m['name']:22s} gate exit={rc}  {verdict}   {last}")
      finally:
        open(SRC, "w").write(original)

    md5_after = md5(SRC)
    print(f"MD5   after  {md5_after}")
    ok = (caught == len(MUTANTS)) and (md5_after == md5_before)
    print(f"MUTATION RESULT: {'PASS' if ok else 'FAIL'} "
          f"({caught}/{len(MUTANTS)} caught, md5 "
          f"{'restored' if md5_after == md5_before else ' NOT RESTORED'})")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
