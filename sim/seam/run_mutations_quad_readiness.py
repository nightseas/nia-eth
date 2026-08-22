#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_mutations_quad_readiness.py
# Description : The mutation gate of the transceiver quad readiness check, over its own
#               fixture.
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
GATE = os.path.join(HERE, "..", "gate", "gate_quad_readiness.py")
MAC = os.path.join(RTL, "dcmac_mac_group.sv")
SYNC = os.path.join(RTL, "dcmac_sync2.sv")
FIXTURE = os.path.join(HERE, "..", "tb", "fixtures", "quad_readiness_good.sv")

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root

MUTANTS = [
    dict(
        id="R19M1", check="C2", file=MAC,
        anchor="    for (int qq = 0; qq < N_CLIENT; qq++) begin",
        replace="    for (int qq = 0; qq < 1; qq++) begin",
        why=" THE MUTANT  NAMES: quad 1 is dropped from the GT-readiness AND, so the "
            "sequencer is released while the SECOND cage is still in reset. On the wire that is a "
            "link that SOMETIMES comes up - the intermittency shape this program has paid for "
            "twice (6/10 -> 15/15 with the RX-only escalation;  7/10 -> 20/20).",
    ),
    dict(
        id="R19M2", check="C1", file=MAC,
        anchor="    dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_tx_done (",
        replace="    dcmac_sync2 #(.WIDTH(8), .STAGES(1), .INIT(8'h00)) u_sync_tx_done (",
        why="Quad q's TX-reset-done synchroniser collapses to ONE stage.  NO SIMULATION CAN SEE "
            "THIS - an ideal clock model captures a single flop happily and the design then fails "
            "in the BUILD.  was 213 of 213 failing setup endpoints, found by enumerating "
            "the port list rather than by any test. (`dcmac_sync2` also $fatal()s on it at "
            "elaboration; this gate is the pre-elaboration half.)",
    ),
    dict(
        id="R19M3", check="C4", file=MAC,
        anchor="      .din  (gt_tx_reset_done_raw[8*q +: 8]),",
        replace="      .din  (gt_tx_reset_done_raw[0 +: 8]),",
        why=" NAME-ONLY COMPLIANCE, the failure mode a textual gate is most likely to miss: "
            "every quad's chain still exists, still has 2 ASYNC_REG stages, and still drives a "
            "per-quad slice of `gt_tx_done_sync` - but they all capture QUAD 0's word. 's "
            "' replicated, NOT shared' violated with the structure left intact. This is the "
            "real-RTL form of the mutant that forced C4 into existence in wave 1.",
    ),
    dict(
        id="R19M4", check="C2", file=MAC,
        anchor="      gt_tx_done_all &= gt_tx_done_sync[8*qq +: 8];",
        replace="      gt_tx_done_all |= gt_tx_done_sync[8*qq +: 8];",
        why="The reduction becomes an OR, so readiness is declared as soon as EITHER quad is "
            "done. Same hazard as R19M1 by a different route, and one character wide.: the "
            "readiness shall AND both quads' synchronised words.",
    ),
    dict(
        id="R19M5", check="C3", file=MAC,
        anchor="      gt_rx_done_all &= gt_rx_done_sync[8*qq +: 8];",
        replace="      gt_rx_done_all &= gt_rx_reset_done_raw[8*qq +: 8];",
        why=" 's LITERAL SHAPE: the readiness comparator reads the RAW asynchronous word, "
            "bypassing the crossing entirely, while the synchroniser sits there unused and the "
            "code still looks right.  and  were this mistake TWICE IN THE SAME FILE, "
            "both times behind the sentence 'no combinational path crosses a domain boundary "
            "anywhere'.",
    ),
    dict(
        id="R19M6", check="C0", file=SYNC,
        anchor='  (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sr [0:STAGES-1];',
        replace="  reg [WIDTH-1:0] sr [0:STAGES-1];",
        why="The `ASYNC_REG` attribute is deleted from the ONE module every crossing in the seam "
            "now goes through - so all six of them lose it at once.  THIS IS THE MUTANT THE "
            "WAVE-1 GATE COULD NOT EVEN EXPRESS: it looked for the attribute in the file under "
            "test, and in this idiom the attribute is not there.: `get_property ASYNC_REG` "
            "is not a witness, `report_cdc`'s 'No ASYNC_REG' column is - and this gate is the "
            "pre-build half of that same check.",
    ),
]

def md5(p):
    with open(p, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def run_gate(extra=None):
    r = subprocess.run([sys.executable, GATE] + list(extra or []),
                       capture_output=True, text=True)
    last = ""
    for ln in r.stdout.strip().splitlines():
        if ln.startswith("TOTAL "):
            last = ln
    return r.returncode, last or "(no TOTAL line)"

def preflight():
    bad = 0
    cache = {}
    for m in MUTANTS:
        cache.setdefault(m["file"], open(m["file"]).read())
        n = cache[m["file"]].count(m["anchor"])
        print("%s %-6s anchor x%d  %-26s [%s]"
              % ("OK " if n == 1 else "BAD", m["id"], n, os.path.basename(m["file"]), m["check"]))
        if n != 1:
            bad += 1
    print("TOTAL %d BAD %d" % (len(MUTANTS), bad))
    return bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preflight", action="store_true")
    ap.add_argument("--legacy-fixture", action="store_true",
                    help="also gate the fixture quad_readiness_good.sv (RETIRED - the inline idiom)")
    a = ap.parse_args()

    files = sorted({m["file"] for m in MUTANTS})
    for f in files:
        print("TARGET  %s" % f)
    print(" REAL RTL, not a fixture (audit ). This stage mutates and restores; it does not "
          "own these files.")
    md5_before = {f: md5(f) for f in files}
    for f in files:
        print("MD5     before %s  %s" % (md5_before[f], os.path.basename(f)))

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
        print("MUTATION RESULT: FAIL (the conformant RTL does not pass the gate; fix that first - "
              "this is exactly the  condition, where the gate reported the good design bad)")
        return 1

    originals = {f: open(f).read() for f in files}
    caught, rows = 0, []
    with rtl_lock(nia_rtl_root(__file__), who="run_mutations_quad_readiness.py"):
        try:
            for m in MUTANTS:
                f = m["file"]
                open(f, "w").write(originals[f].replace(m["anchor"], m["replace"], 1))
                rc, last = run_gate()
                verdict = "CAUGHT" if rc != 0 else "NOT CAUGHT"
                caught += 1 if rc != 0 else 0
                rows.append((m["id"], m["check"], os.path.basename(f), m["why"], verdict))
                print("MUT     %-6s [%s] %-26s gate exit=%d  %-10s %s"
                      % (m["id"], m["check"], os.path.basename(f), rc, verdict, last))
                open(f, "w").write(originals[f])
        finally:
            for f in files:
                open(f, "w").write(originals[f])

    md5_after = {f: md5(f) for f in files}
    restored = all(md5_after[f] == md5_before[f] for f in files)
    for f in files:
        print("MD5     after  %s  %s  %s"
              % (md5_after[f], os.path.basename(f),
                 "restored" if md5_after[f] == md5_before[f] else " NOT RESTORED"))

    print("\n| mutant | file | gate check | injected defect | verdict |")
    print("|---|---|---|---|---|")
    for mid, chk, fn, why, verdict in rows:
        print("| %s | `%s` | %s | %s | %s |" % (mid, fn, chk, why, verdict))

    legacy_rc = 0
    if a.legacy_fixture:
        print("\n=== RETIRED fixture (expected to FAIL: it is the inline idiom  excludes) ===")
        legacy_rc, last = run_gate([FIXTURE])
        print("LEGACY  gate exit=%d  %s  -> %s"
              % (legacy_rc, last,
                 "correctly rejected" if legacy_rc else " UNEXPECTED PASS"))

    ok = (caught == len(MUTANTS)) and restored
    print("MUTATION RESULT: %s (%d/%d caught against the REAL RTL, md5 %s)"
          % ("PASS" if ok else "FAIL", caught, len(MUTANTS),
             "restored" if restored else " NOT RESTORED"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
