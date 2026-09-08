#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_mutations_dual.py
# Description : The mutation gate of the two client subsystem, which additionally checks
#               that every mutant names a test that exists.
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
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
LOGDIR = os.environ.get("LOGDIR", os.path.join(HERE, "logs_dual"))

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

SUITE_WALL_S = float(os.environ.get("SUITE_WALL_S", "700"))

BASE = {"SEED": "1", "TX_MHZ": "250", "RX_MHZ": "250",
        "ANCHOR_C0": "0", "ANCHOR_C1": "1", "NPORTS_C0": "1", "NPORTS_C1": "1"}
NPORTS2 = dict(BASE, NPORTS_C0="2", ANCHOR_C0="0", NPORTS_C1="2", ANCHOR_C1="2")

FSM = "ctl/dcmac_mac_ctl_fsm.sv"
ADAPTER = "dcmac_seg_axis_adapter.sv"
SEG_RX  = "dcmac_seg_axis_rx.sv"

A_GROUP_MASK = ("      if (p >= ANCHOR && p < (ANCHOR + NPORTS)) port_group_mask[p] = 1'b1;")
A_RX_SEG_ENA = "      in_take[s] = rx_seg_valid & rx_seg_ena[s];\n"

MUTANTS = [
    dict(
        id="D1", status="applicable", file=FSM, variant=BASE,
        anchor=A_GROUP_MASK,
        replace="      port_group_mask[p] = 1'b1;",
        clause="",
        what=" THE RUN'S HEADLINE MUTANT. The per-client port-group mask is widened to EVERY "
              "MAC port, so client k's re-align drives the other client's slot onto the ONE "
              "shared MAC-port reset bus and resets its quad. This is 's defect in its "
              "dual-port form; on the wire it is an intermittency (400GAUI-4 7/10 -> 20/20; "
              "cross-cage dual-200G 6/10 -> 15/15).  WAVE 4: `expect` narrowed from three tests "
              "to one. The two `test_ns21_align_loss_on_c*` tests it also named were REMOVED from "
              "the suite (they were unimplementable against a core-level DUT - see the  block in "
              "`test_dcmac_dual.py`), and because `caught` requires EVERY named test to fail, "
              "leaving them here would have made this mutant permanently unscoreable. The "
              "surviving test is the one that actually reads `port_group_mask`.",
        expect=["test_ns21_group_masks_disjoint_and_owned"],
        also_scored_by="the cross-client half: run_mutations_reset_sync.py R27M4/R27M2 on the real PHY, "
                       "and test_dcmac_mac_dual.py's test_ns21_b2_* pair",
    ),
    dict(
        id="D3", status="applicable", file=FSM, variant=NPORTS2,
        anchor=A_GROUP_MASK,
        replace="      if (p == ANCHOR) port_group_mask[p] = 1'b1;",
        clause="",
        what="The OTHER half of  only the ANCHOR port is reset, not the whole group.  This "
              "is INVISIBLE at NPORTS=1 (the group is one bit), which is why it is pinned to the "
              "`nports2` variant - and why that variant exists. It is the literal 7/10 -> 20/20 defect, "
              "now per client.",
        expect=["test_ns21_group_masks_disjoint_and_owned"],
    ),
    dict(
        id="D4", status="applicable", file=SEG_RX, variant=BASE,
        anchor="          slot_load_next[write_slot_next] = 1'b1;",
        replace="          slot_load_next[write_slot_next] = (lane == 0);\n",
        clause=" / ",
        what="A lost segment on the RX seam. Scored here not because it is new - the "
              "single-client M1 covers the mechanism - but because it must fail the CONCURRENT "
              "two-client byte-exactness test, proving that test compares BOTH clients' payloads "
              "and not just client 0's. A dual suite that only ever really checks client 0 is the "
              "most likely way this gate would be quietly worthless.",
        expect=["test_ns17_concurrent_rx_byte_exact_both"],
    ),

    dict(
        id="D5", status="resolved_elsewhere", file="dcmac_mac_group.sv", variant=BASE,
        anchor="<RESOLVED ELSEWHERE: run_mutations_quad_readiness.py R19M1, on the real RTL>",
        replace="<RESOLVED ELSEWHERE>",
        clause="",
        what=" THE  MUTANT the run asks for: drop quad 1 from the GT-readiness AND, so the "
              "sequencer declares the GT ready while the second quad is still in reset.  NOT "
              "SCOREABLE BY THIS SUITE - the per-quad readiness pins live in `dcmac_phy`, "
              "ABOVE the licence-free 2-client DUT. It is scored instead by the STRUCTURAL gate "
              "`gate_quad_readiness.py` in this directory, which is the same technique the "
              "program already uses for a defect class no simulation can see "
              "(`ctl/sim/gate_ctl_seq_waits.py` and ). This entry exists so the "
              "clause is not silently unowned.",
        expect=["<see gate_quad_readiness.py>"],
        scored_by="run_mutations_quad_readiness.py R19M1 (gate_quad_readiness.py C2)",
    ),
    dict(
        id="D6", status="resolved_elsewhere", file="dcmac_phy_wrapper.sv", variant=BASE,
        anchor="<RESOLVED ELSEWHERE: run_mutations_reset_sync.py R27M4 (+ R27M2), on the real PHY>",
        replace="<RESOLVED ELSEWHERE>",
        clause="",
        what="The RTL form of what H1 wires in the harness: a shared per-quad reset. Once "
              "`seam_n6`'s PHY exists this becomes the strongest  mutant, because it lives "
              "in the real fan-out rather than in the model of it. Resolved elsewhere.",
        expect=["<see run_mutations_reset_sync.py R27M4/R27M2 and test_dcmac_mac_dual.py>"],
        scored_by="run_mutations_reset_sync.py R27M4 + R27M2 (gate_dual_port_reset_sync.py P4/P3)",
    ),
]

HARNESS_CONTROLS = [
    dict(
        id="H1", define="SHARED_QUAD_RESET=1", variant=BASE, clause="",
        what=" The harness's OWN negative control: `+define+NIA_DUAL_SHARED_QUAD_RESET` wires "
              "the modelled per-quad reset SHARED, i.e. 's defect, so "
              "`quad_rx_dp_reset = {2{|quad_rx_owned}}`. "
              "`test_ns21_group_masks_disjoint_and_owned` asserts "
              "`quad_rx_dp_reset[1-k] == 0` while client k's reset request is raised, so it MUST "
              "fail under this define. If it passes, this suite has NO  content and no "
              "mutant score below means anything.  WAVE 4: `expect` narrowed from three tests to "
              "this one - the other two were removed from the suite (see the  block in "
              "`test_dcmac_dual.py`), and `caught` requires every named test to fail, so "
              "leaving them would have wedged this control permanently red for the wrong reason.",
        expect=["test_ns21_group_masks_disjoint_and_owned"],
    ),
]

def md5(p):
    with open(p, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def run_suite(tag, mkvars, extra=None):
    os.makedirs(LOGDIR, exist_ok=True)
    xml = os.path.join(LOGDIR, f"results_mutdual_{tag}.xml")
    log = os.path.join(LOGDIR, f"mutdual_{tag}.log")
    subprocess.run(["make", "-f", "Makefile.dual", "-s", "clean"], cwd=HERE, capture_output=True)
    argv = ["make", "-f", "Makefile.dual"] + [f"{k}={v}" for k, v in mkvars.items()]
    if extra:
        argv += list(extra)
    argv += [f"COCOTB_RESULTS_FILE={xml}"]
    with open(log, "w") as fh:
        fh.write("# " + " ".join(argv) + f"\n# SUITE_WALL_S={SUITE_WALL_S}\n")
        fh.flush()
        try:
            subprocess.run(argv, cwd=HERE, stdout=fh, stderr=subprocess.STDOUT,
                           timeout=SUITE_WALL_S)
        except subprocess.TimeoutExpired:
            fh.write(f"\n NIA_WALL_KILL: exceeded SUITE_WALL_S={SUITE_WALL_S}s.: a "
                     f"simulated-time bound cannot bound a hang that freezes simulated time, and "
                     f"a timeout you cannot REACH is not a timeout. This variant is INVALID, NOT "
                     f"CAUGHT.\n")
            return None, None, f"INVALID(STALLED) wall>{SUITE_WALL_S}s", log
    try:
        root = ET.parse(xml).getroot()
    except Exception as e:
        return None, None, f"no/unparsable XML ({e})", log
    tcs = list(root.iter("testcase"))
    return len(tcs), [c.get("name") for c in tcs if len(list(c))], None, log

SUITE = os.path.join(HERE, "test_dcmac_dual.py")

def suite_test_names():
    import re
    src = open(SUITE).read()
    return set(re.findall(r"^async def (test_\w+)\(", src, re.M))

def check_expect_names():
    have = suite_test_names()
    bad = 0
    scored = [m for m in MUTANTS if m["status"] == "applicable"] + HARNESS_CONTROLS
    for m in scored:
        for e in m["expect"]:
            if e.startswith("<"):
                continue
            if e not in have:
                print(f"BAD  {m['id']:3s} expect names `{e}`, which `test_dcmac_dual.py` does "
                      f"NOT define  this mutant could never be scored")
                bad += 1
    print(f"EXPECT_NAMES {'OK' if not bad else 'BAD ' + str(bad)}  "
          f"(suite defines {len(have)} tests: {', '.join(sorted(have))})")
    return bad

def preflight():
    applicable = [m for m in MUTANTS if m["status"] == "applicable"]
    declared = [m for m in MUTANTS if m["status"] == "declared"]
    resolved = [m for m in MUTANTS if m["status"] == "resolved_elsewhere"]
    bad = 0
    for m in applicable:
        path = os.path.join(RTL, m["file"])
        if not os.path.exists(path):
            print(f"BAD  {m['id']:3s} anchor x?  {m['file']}: FILE MISSING")
            bad += 1
            continue
        n = open(path).read().count(m["anchor"])
        if n == 1:
            print(f"OK   {m['id']:3s} anchor x1  {m['file']}  [{m['clause']}]")
        else:
            print(f"BAD  {m['id']:3s} anchor x{n}  {m['file']}  [{m['clause']}] "
                  f" expected exactly 1")
            bad += 1
    bad += check_expect_names()
    print(f"TOTAL {len(applicable)} BAD {bad}")
    for m in resolved:
        print(f"RSLV {m['id']:3s} {m['file']} [{m['clause']}] - NOT scored here; scored against "
              f"the REAL RTL by {m.get('scored_by', '?')}")
    for m in declared:
        print(f"DECL {m['id']:3s} {m['file']} [{m['clause']}] - target owned by `seam_n6`, "
              f"anchor transcribed from the interface and NOT verified against any file"
              + (f"; scored by {m['scored_by']}" if m.get("scored_by") else ""))
    print(f"RESOLVED_ELSEWHERE {len(resolved)}")
    print(f"DECLARED {len(declared)}")
    return bad, len(declared)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("only", nargs="?", default=None)
    ap.add_argument("--preflight", action="store_true")
    ap.add_argument("--allow-declared", action="store_true",
                    help="score only the applicable mutants and still print PASS.  Use ONLY "
                         "when the lead has recorded why the declared entries are deferred; the "
                         "default refusal exists because an unresolved anchor is a coverage hole "
                         "that looks like a clean run.")
    args = ap.parse_args()

    bad, n_declared = preflight()
    if bad:
        print("\nMUTATION RESULT: FAIL (stale anchors - fix the catalogue, not the RTL)")
        return 2
    if args.preflight:
        return 0

    rows = []

    for h in HARNESS_CONTROLS:
        n, failed, err, log = run_suite(h["id"], dict(h["variant"], **{}),
                                        extra=[h["define"]])
        caught = err is None and failed and all(any(e in f for f in failed) for e in h["expect"])
        rows.append((h["id"], "<harness define>", h["clause"], h["what"], h["expect"],
                     n, failed, err, caught, log))
        print(f"{h['id']}: tests={n} failed={failed} err={err} caught={caught}  log={log}")
        if not caught:
            print("\n MUTATION RESULT: FAIL - the harness negative control did NOT fail the "
                  " tests. Those tests are not observing the per-quad reset at all, so no "
                  "mutant score below would mean anything. Fix the tests before the RTL.")
            return 4

    variants = {}
    for m in MUTANTS:
        if m["status"] != "applicable":
            continue
        variants[tuple(sorted(m["variant"].items()))] = m["variant"]
    for key, env in variants.items():
        tag = "base_" + "_".join(f"{k}{v}" for k, v in sorted(env.items()) if k != "SEED")
        n, failed, err, log = run_suite(tag, env)
        print(f"BASELINE {env}: tests={n} failed={failed} err={err}  log={log}")
        if err is not None or failed:
            print("\nMUTATION RESULT: FAIL (a baseline variant is already red; fix that first)")
            return 3

    with rtl_lock(nia_rtl_root(__file__), who=f"run_mutations_dual.py ({args.only or 'all'})"):
        for m in MUTANTS:
            if args.only and m["id"] != args.only:
                continue
            if m["status"] != "applicable":
                print(f"{m['id']}: SKIPPED (declared, target owned by `seam_n6`)")
                continue
            path = os.path.join(RTL, m["file"])
            orig = open(path).read()
            orig_md5 = md5(path)
            assert m["anchor"] in orig, f"{m['id']}: anchor vanished after pre-flight"
            open(path, "w").write(orig.replace(m["anchor"], m["replace"], 1))
            assert md5(path) != orig_md5, f"{m['id']}: mutation did not change the file"
            try:
                n, failed, err, log = run_suite(m["id"], m["variant"])
            finally:
                open(path, "w").write(orig)
                assert md5(path) == orig_md5, f"{m['id']}: FAILED TO REVERT {m['file']}"
            caught = (err is None and failed is not None and len(failed) > 0 and
                      all(any(e in f for f in failed) for e in m["expect"]))
            rows.append((m["id"], m["file"], m["clause"], m["what"], m["expect"],
                         n, failed, err, caught, log))
            print(f"{m['id']}: tests={n} failed={failed} err={err} caught={caught}")

    print("\n| id | file | clause | injected defect | expected to fail | observed | caught |")
    print("|---|---|---|---|---|---|---|")
    ok = True
    for mid, f, cl, what, expect, n, failed, err, caught, log in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{f}` | {cl} | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} |")
        ok &= caught
    if n_declared and not args.allow_declared:
        print(f"\nMUTATION RESULT: INCOMPLETE - {n_declared} DECLARED mutant(s) were never "
              f"applied because `seam_n6`'s files did not exist when this catalogue was written. "
              f"They are not failures and they are not passes. Resolve their anchors (or record "
              f"why they are deferred and pass --allow-declared).")
        return 5
    print(f"\nMUTATION RESULT: {'PASS (every applicable mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
