#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_ctl_seq_mutations_dual.py
# Description : The mutation gate of the two group sequencer.
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
GATE = os.path.join(HERE, "..", "gate", "gate_ctl_seq_groups.py")

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

A_ANCH = "    return (g == 0) ? ANCHOR : ANCHOR_1;"
A_IS_ANCH = "    return (p == ANCHOR) || ((NG > 1) && (p == ANCHOR_1));"
A_NG = "  localparam int NG        = N_GROUP;"
A_P_B5W = "  localparam int P_B5W    = P_B5C    + 5*NP*NG;"
A_P_B17 = "  localparam int P_B17    = P_B11    + 2*NP*NG;"
A_B5C_W = ("          2: begin op = OP_WAIT; w = (32'(T_CHAN_ASSERT_MS) * 32'(CYC_PER_MS)); end")

MUTANTS = [
    dict(
        name="G2M1_anch_collapsed_to_group0", check="S1",
        anchor=A_ANCH, replace="    return ANCHOR;",
        why=" THE RUN'S FIRST NAMED MUTANT - 'delete the second group's writes', in one line. "
            "`anch()` is the RTL's own 'ONLY place group -> first-MAC-slot is decided'. Collapsed, "
            "EVERY group resolves to group 0's ports, so group 1's per-port writes vanish from "
            "B5C, B9C, B11, the B12 poll AND the B13 ladder at once. The image would program one "
            "cage and report two ports.",
    ),
    dict(
        name="G2M2_is_anch_drops_group1", check="S2",
        anchor=A_IS_ANCH, replace="    return (p == ANCHOR);",
        why="Group 1's anchor no longer counts as an anchor, so B8's rate/field words go only to "
            "slot 0 and the SECOND cage is left at rate 0.  This is the most silicon-like of the "
            "mutants: every register write still happens, the ROM still completes, and the second "
            "link simply never aligns - which is indistinguishable from a polarity or silicon "
  "problem on a board (cf., where getting polarity wrong 'looks like silicon').",
    ),
    dict(
        name="G2M4_b5c_chan_assert_wait_unscaled", check="S6",
        anchor=A_B5C_W,
        replace="          2: begin op = OP_WAIT; w = 32'(T_CHAN_ASSERT_MS); end",
        why="The same class on the 5 ms settle between a group's CHANNEL and PORT asserts - the "
            "wait `golden.py` annotates as '5 ms here (2B:797)'. It is inside the per-group B5C "
            "block, so with two groups it is executed once PER PORT of BOTH groups; unscaling it "
            "shortens every one of them.",
    ),
    dict(
        name="G2M5_ng_forced_to_1", check="S3",
        anchor=A_NG,
        replace="  localparam int NG        = 1;",
        why="`NG` decoupled from the `N_GROUP` parameter. Every group-scoped size and base "
            "collapses to the pre-N6 value while the parameter still reads 2 - so the ROM programs "
            "one group and the integrator has no signal that anything is wrong.  This mutant "
            "passes EVERY single-client variant by construction, which is the whole argument for a "
            "structural gate here.",
    ),
    dict(
        name="G2M6_b5c_section_loses_group_dim", check="S4",
        anchor=A_P_B5W,
        replace="  localparam int P_B5W    = P_B5C    + 5*NP;",
        why="B5's per-group channel-assert SECTION loses its `NG`, so group 1's CHCTL/PCTL asserts "
            "are not merely wrong - their ROM records DO NOT EXIST, and every later PC base is "
            "shifted. The coarser sibling of G2M1: same outcome, different mechanism, and it is "
            "the mechanism a hand-edited localparam block would actually produce.",
    ),
    dict(
        name="G2M8_b17_loses_group_dim", check="S5",
        anchor=A_P_B17,
        replace="  localparam int P_B17    = P_B11    + 2*NP;",
        why="B17 no longer sits at `P_B11 + 2*NP*NG`, so B11's per-group CHANNEL release is sized "
            "for ONE group: group 1's release records do not exist and every later base is "
            "shifted. It is the same class as G2M6 -- a group-scoped section losing its `NG` -- on "
            "the section that check S5 now guards, and it is also the mechanical form of 'removing "
            "the poll block was a truncation, not a rewrite'. Invisible at N_GROUP = 1, which is "
            "every single-client variant, and the comment is deliberately left reading `(2*NP*NG)` so "
            "the mutant is a code change a careless hand edit would really produce. "
  "THIS MUTANT REPLACED G2M7: G2M7 scored S5 when S5 asserted the retry "
            "ladder was per group, and the ladder is deleted. S5's property moved, so its scoring "
            "mutant moved with it -- a gate check with no mutant behind it is a gate nobody has "
            "shown can fail.",
    ),
]

def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def preflight(text):
    bad = 0
    for m in MUTANTS:
        n = text.count(m["anchor"])
        print(f"{'OK ' if n == 1 else 'BAD'} anchor x{n}  {m['name']:36s} [{m['check']}]")
        if n != 1:
            bad += 1
    print(f"TOTAL {len(MUTANTS)} BAD {bad}")
    return bad

def run_gate():
    r = subprocess.run([sys.executable, GATE, SRC], capture_output=True, text=True)
    tail = [ln for ln in r.stdout.strip().splitlines() if ln.startswith("TOTAL ")]
    return r.returncode, (tail[-1] if tail else "<no TOTAL line>")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preflight", action="store_true")
    args = ap.parse_args()

    original = open(SRC).read()
    md5_before = md5(SRC)
    print(f"SRC   {SRC}")
    print(f"MD5   before {md5_before}")

    if preflight(original):
        print("MUTATION RESULT: FAIL (stale anchors - `seam_n6` moved the RTL. Fix the catalogue, "
              "not the RTL, and re-read the md5 in this file's header)")
        return 1
    if args.preflight:
        return 0

    rc, last = run_gate()
    print(f"BASE  gate exit={rc}  {last}")
    if rc != 0:
        print("MUTATION RESULT: FAIL (the baseline is already red; fix that first)")
        return 1

    caught = 0
    rows = []
    with rtl_lock(nia_rtl_root(__file__), who="run_ctl_seq_mutations_dual.py"):
        try:
            for m in MUTANTS:
                open(SRC, "w").write(original.replace(m["anchor"], m["replace"], 1))
                rc, last = run_gate()
                verdict = "CAUGHT" if rc != 0 else "NOT CAUGHT"
                if rc != 0:
                    caught += 1
                rows.append((m["name"], m["check"], m["why"], verdict, last))
                print(f"MUT   {m['name']:36s} [{m['check']}] gate exit={rc}  {verdict}  {last}")
        finally:
            open(SRC, "w").write(original)

    md5_after = md5(SRC)
    print(f"MD5   after  {md5_after}")

    print("\n| mutant | gate check | injected defect | verdict |")
    print("|---|---|---|---|")
    for name, chk, why, verdict, _ in rows:
        print(f"| {name} | {chk} | {why} | {verdict} |")

    ok = (caught == len(MUTANTS)) and (md5_after == md5_before)
    print(f"\nMUTATION RESULT: {'PASS' if ok else 'FAIL'} ({caught}/{len(MUTANTS)} caught, md5 "
          f"{'restored' if md5_after == md5_before else ' NOT RESTORED'})")
    print(" SCOPE: this scores the STRUCTURAL gate only. The behavioural half - that the emitted "
          "trace contains every per-port write for BOTH slots, in order, with the ms waits intact "
          "- is `test_dcmac_ctl_seq_dual.py`, WRITTEN AND UNRUN (the lead owns dispatch).")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
