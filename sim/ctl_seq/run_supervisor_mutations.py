#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_supervisor_mutations.py
# Description : The mutation gate of the watchdog window register, run as a control and a
#               mutant pair. The mutants of dcmac_link_ctl.sv were removed on 2026-09-09:
#               their anchor lines are absent from that file at fdfb099 and earlier, and
#               two of them named a test that exists in no file, so they tested nothing.
#               Link control mutation coverage is owed by the link control scope.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CSR = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_link_csr.sv"))

MUTANTS = [
  ("M9_the_clamp_is_not_applied", "", CSR, "Makefile.wdt_register", "CSR_SRC",
     [("      assign wdt_eff_flat[gi*16 +: 16] = wdt_clamp(wdt_req_r[gi]);",
       "      assign wdt_eff_flat[gi*16 +: 16] = wdt_req_r[gi];")],
     ["test_ns59_the_value_reaches_the_tx_domain"], []),

  ("M10_a_written_zero_means_expire_immediately", "", CSR, "Makefile.wdt_register", "CSR_SRC",
     [("    if (req == 16'd0)                     wdt_clamp = 16'(LINK_WDT_MS);",
       "    if (req == 16'd0)                     wdt_clamp = 16'd0;")],
     ["test_ns59_zero_means_the_parameter"], []),

  ("M11_the_W1C_also_rewrites_the_window", "", CSR, "Makefile.wdt_register", "CSR_SRC",
     [("            if (!(cm_strb[3] && cm_data[30])) begin",
       "            if (1'b1) begin")],
     ["test_ns59_sticky_is_w1c_and_leaves_the_window"], []),
]

def run_arm(makefile, src_var, src_path, testcase, extra, tag):
    env = dict(os.environ)
    env["SIM_BUILD"] = os.path.join(HERE, tag)
    env["TESTCASE"] = testcase
    env["COCOTB_RESULTS_FILE"] = os.path.join(HERE, tag + ".xml")
    cmd = ["make", "-f", makefile, f"{src_var}={src_path}",
           f"SIM_BUILD={env['SIM_BUILD']}",
           f"COCOTB_RESULTS_FILE={env['COCOTB_RESULTS_FILE']}"] + extra
    subprocess.run(["rm", "-rf", env["SIM_BUILD"], env["COCOTB_RESULTS_FILE"]], check=False)
    try:
        p = subprocess.run(cmd, cwd=HERE, env=env, capture_output=True, text=True, timeout=2400)
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"
    out = p.stdout + p.stderr
    m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
    if not m:
        return None, out
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))), out

def main():
    tmpdir = tempfile.mkdtemp(prefix="ns54_mut_")
    print(f"MUTATION dir {tmpdir}", flush=True)
    sources = {CSR: open(CSR).read()}

    controls = []
    for name, _c, src, mk, var, _s, tests, extra in MUTANTS:
        for t in tests:
            key = (src, mk, var, t, tuple(extra))
            if key not in controls:
                controls.append(key)
    for src, mk, var, t, extra in controls:
        res, out = run_arm(mk, var, src, t, list(extra), "sb_ns54_ctl")
        ok = res is not None and res[2] == 0 and res[1] >= 1
        print(f"CONTROL {mk} {t} {' '.join(extra)}: {'PASS' if ok else 'FAIL'} {res}", flush=True)
        if not ok:
            print(out[-3000:])
            print(" CONTROL FAILED - a 'caught' mutant would be meaningless. Stopping.")
            return 2

    results = []
    for name, clause, src, mk, var, subs, tests, extra in MUTANTS:
        body = sources[src]
        bad = False
        for find, repl in subs:
            if body.count(find) != 1:
                print(f"MUTANT {name}:  ANCHOR NOT UNIQUE (count={body.count(find)}) - the RTL "
                      f"moved under this mutant. HARD ERROR, not a skip: a mutant whose anchor is "
                      f"gone silently stops testing its clause.", flush=True)
                bad = True
                break
            body = body.replace(find, repl)
        if bad:
            results.append((name, clause, "ANCHOR"))
            continue
        mut_path = os.path.join(tmpdir, f"{name}_{os.path.basename(src)}")
        with open(mut_path, "w") as fh:
            fh.write(body)
        caught = []
        for t in tests:
            res, _ = run_arm(mk, var, mut_path, t, extra, "sb_ns54_m")
            caught.append(res is None or res[2] >= 1)
        verdict = "CAUGHT" if any(caught) else "SURVIVED"
        results.append((name, clause, verdict))
        print(f"MUTANT {name} [{clause}] {verdict}  tests={list(zip(tests, caught))}", flush=True)

    print()
    print("%-52s %-16s %s" % ("mutant", "clause", "verdict"))
    n_caught = 0
    for name, clause, verdict in results:
        print("%-52s %-16s %s" % (name, clause, verdict))
        if verdict == "CAUGHT":
            n_caught += 1
    scored = [r for r in results if r[2] in ("CAUGHT", "SURVIVED")]
    print()
    print(f"NS54_MUTATION RESULT: {'PASS' if n_caught == len(scored) and scored else 'FAIL'} "
          f"{n_caught}/{len(scored)} caught")
    return 0 if (n_caught == len(scored) and scored) else 1

if __name__ == "__main__":
    sys.exit(main())
