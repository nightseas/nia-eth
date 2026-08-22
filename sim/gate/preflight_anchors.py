#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : preflight_anchors.py
# Description : Checks that every mutation a set declares still binds to the text it means
#               to mutate, before a dispatch spends a simulator on it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import argparse
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
CTL_SIM = os.path.normpath(os.path.join(HERE, "..", "ctl_seq"))
SIM_IP = os.path.normpath(os.path.join(HERE, "..", "ip"))

SUBPROCESS_CATALOGUES = [
    ("sim/run_mutations_dual.py", [sys.executable, os.path.join(HERE, "..", "seam", "run_mutations_dual.py"),
                                   "--preflight"], HERE),
    ("sim/run_mutations_quad_readiness.py", [sys.executable, os.path.join(HERE, "..", "seam", "run_mutations_quad_readiness.py"),
                                   "--preflight"], HERE),
    ("sim/run_mutations_reset_sync.py", [sys.executable, os.path.join(HERE, "..", "seam", "run_mutations_reset_sync.py"),
                                   "--preflight"], HERE),
    ("sim/ctl_seq/run_ctl_seq_mutations.py",
     [sys.executable, os.path.join(CTL_SIM, "run_ctl_seq_mutations.py"), "--preflight"], CTL_SIM),
    ("sim/ctl_seq/run_ctl_seq_mutations_dual.py",
     [sys.executable, os.path.join(CTL_SIM, "run_ctl_seq_mutations_dual.py"), "--preflight"],
     CTL_SIM),
    ("sim/ip/mutate_ip.py", [sys.executable, os.path.join(SIM_IP, "mutate_ip.py"),
                             "--preflight"], SIM_IP),
]

KNOWN_FINDINGS = r"""
================================ DIAGNOSED FINDINGS ================================
 **CLOSED  (wave 3) - M13 in `sim/run_mutations.py`. Audit finding.**

  The anchor was
      rx_rst_seg <= ~seg_rstn | ~link_up_i | ~stat_rx_aligned;
  and `dcmac_axis_adapter.sv:330` reads
  rx_rst_seg <= ~seg_rstn | ~link_up_i | ~stat_rx_aligned_seg;: the synchronised copy

  The operand was renamed when  was fixed - the crossing that needed the SYNCHRONISED copy of
  `stat_rx_aligned` - and the mutant was never re-anchored. FIXED: the anchor now names
  `~stat_rx_aligned_seg`, and `run_mutations.py`'s md5 is RE-PINNED in `run_matrix_seam_boundary.sh`
  (`63053614...` -> `704e74b5...`) with the reason recorded there. This aggregator now prints
  `TOTAL 43 BAD 0`; it printed `TOTAL 42 BAD 1` before, and the audit reproduced that
  independently.

   **THE LESSON IS NOT THE TOKEN.** `run_mutations.py`'s own pre-flight is fail-closed, so for as
  long as the anchor was stale **the entire 16-mutant single-client catalogue scored ZERO mutants**
  - the suite that proves the 384-run gate can fail was itself inoperative, silently, from the
  moment the  fix landed. A mutation catalogue stops covering anything the instant an anchor
  drifts, and nothing about that is visible in a green test log. That is why Rule 6 makes the
  anchor pre-flight mandatory, why this aggregator exists, and why it prints a GRAND total across
  every catalogue rather than a per-catalogue verdict anyone can read past.

   Still OWED (needs a simulator, so the LEAD owns it): run `./run_mutations.py M13` and confirm
  it now fails `test_rxrst_latency`. The anchor binds - that is text, and it is proved above - but
  "the mutant breaks the named test" is a claim only a dispatch can make.
====================================================================================
"""

def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

def _run_mutations_count():
    path = os.path.join(HERE, "..", "seam", "run_mutations.py")
    if not os.path.exists(path):
        return []
    return _load(path, "_n6_run_mutations_count").MUTANTS

def check_run_mutations(verbose=True):

    path = os.path.join(HERE, "..", "seam", "run_mutations.py")
    if not os.path.exists(path):
        print("BAD  sim/run_mutations.py MISSING")
        return 1, 1
    sys.path.insert(0, HERE)
    mod = _load(path, "_n6_run_mutations")
    n = bad = 0
    for entry in mod.MUTANTS:
        mid, fname, old = entry[0], entry[1], entry[2]
        n += 1
        fp = os.path.join(RTL, fname)
        if not os.path.exists(fp):
            print(f"BAD  {mid:4s} {fname}: FILE MISSING")
            bad += 1
            continue
        cnt = open(fp).read().count(old)

        if cnt == 1:
            if verbose:
                print(f"OK   {mid:4s} anchor x1  {fname}")
        else:
            print(f"BAD  {mid:4s} anchor x{cnt}  {fname}   expected exactly 1")
            bad += 1
    return n, bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    grand_n = grand_bad = 0
    per = []
    declared_total = 0

    print(f"=== sim/run_mutations.py (EXISTING single-client, {len(_run_mutations_count())} "
          f"mutants) ===")
    n, bad = check_run_mutations(verbose=not a.quiet)
    print(f"TOTAL {n} BAD {bad}")
    per.append(("sim/run_mutations.py", n, bad))
    grand_n += n
    grand_bad += bad

    for label, argv, cwd in SUBPROCESS_CATALOGUES:
        print(f"\n=== {label} ===")
        if not os.path.exists(argv[1]):
            print(f"BAD  {argv[1]} MISSING")
            per.append((label, 0, 1))
            grand_bad += 1
            continue
        r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
        out = r.stdout.strip().splitlines()
        n = bad = 0
        for ln in out:
            if ln.startswith("TOTAL "):
                parts = ln.split()
                try:
                    n, bad = int(parts[1]), int(parts[3])
                except (IndexError, ValueError):
                    pass
            if ln.startswith("DECLARED "):
                try:
                    declared_total += int(ln.split()[1])
                except (IndexError, ValueError):
                    pass
            if not a.quiet or ln.startswith(("TOTAL ", "BAD ", "DECL", "DECLARED ")):
                print(ln)
        if r.returncode != 0 and bad == 0:
            print(f"BAD  {label}: exited {r.returncode} with a clean TOTAL - investigate")
            print((r.stderr or "").strip()[:800])
            bad += 1
        per.append((label, n, bad))
        grand_n += n
        grand_bad += bad

    print("\n=== SUMMARY ===")
    for label, n, bad in per:
        print(f"{'OK ' if bad == 0 else 'BAD'} {label:42s} anchors={n:3d} bad={bad}")
    print(f"TOTAL {grand_n} BAD {grand_bad}")
    if declared_total:
        print(f"DECLARED {declared_total}   mutants whose target file is `seam_n6`'s and whose "
  f"anchor was transcribed from the interface rather than read. They are NOT covered by "
              f"the TOTAL above and they are neither passes nor failures - resolve them against "
              f"`seam_n6`'s final files, then re-run this pre-flight.")
    print(f"PREFLIGHT RESULT: {'PASS' if grand_bad == 0 else 'FAIL'}")
    if grand_bad:
        print(KNOWN_FINDINGS)
    return 0 if grand_bad == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
