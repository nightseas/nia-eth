#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_drp_bridge_mutations.py
# Description : The mutation gate of the reconfiguration bridge.
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
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "dcmac_drp_bridge.sv"))

MUTANTS = [
  ("B1_high_half_refetches_from_the_bus", " (tearing)",
     "            end else if (d_half) begin\n"
  " ----: the high half is the SHADOW. No bus access. ----\n"
     "              ans   <= shadow[31:16];\n"
     "              state <= S_ANS;\n"
     "            end else begin",
     "            end else if (1'b0) begin\n"
     "              ans   <= shadow[31:16];\n"
     "              state <= S_ANS;\n"
     "            end else begin",
     ["test_ns38_halfword_pair_is_coherent", "test_ns38_high_half_issues_no_axi"]),

  ("B2_read_timeout_removed", "  (the never-hang property)",
     "          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin\n"
     "            arv    <= 1'b0;\n"
     "            ans    <= SENT_TIMEOUT;",
     "          end else if (1'b0) begin\n"
     "            arv    <= 1'b0;\n"
     "            ans    <= SENT_TIMEOUT;",
     ["test_ns37_dead_axi_slave_still_answers"]),

  ("B3_wstrb_hardcoded_to_all_bytes", " (per-half writes)",
  "  wstrb_r <= d_half ? 4'b1100: 4'b0011;: per-half, never RMW",
     "              wstrb_r <= 4'b1111;",
     ["test_ns38_write_high_half_preserves_low"]),

  ("B4_out_of_range_forwarded_to_the_bus", " (bounded + silent)",
     "  wire        d_ok   = d_hi_z && (d_word < 6'd16);",
     "  wire        d_ok   = 1'b1;",
     ["test_ns37_out_of_range_answers_and_no_axi"]),

  ("B5_timeout_not_recorded", " (observable through itself)",
     "          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin\n"
     "            rready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;\n"
     "            sts_to   <= 1'b1;",
     "          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin\n"
     "            rready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;\n"
     "            sts_to   <= 1'b0;",
     ["test_ns39_bridge_status_records_the_timeout"]),

  ("B8_read_data_phase_timeout_removed", "  (the path B5 exposed)",
     "          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin\n"
     "            rready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;",
     "          end else if (1'b0) begin\n"
     "            rready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;",
     ["test_ns37_data_phase_stall_still_answers"]),

  ("B9_write_response_timeout_removed", " (the fourth path)",
     "          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin\n"
     "            bready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;",
     "          end else if (1'b0) begin\n"
     "            bready_r <= 1'b0;\n"
     "            ans      <= SENT_TIMEOUT;",
     ["test_ns37_data_phase_stall_still_answers"]),

  ("B6_shadow_keeps_only_the_low_half", " (the shadow is 32 bits)",
  "  shadow  <= m_axil_rdata;: latch ALL 32 bits",
     "            shadow   <= {16'h0, m_axil_rdata[15:0]};",
     ["test_ns38_halfword_pair_is_coherent"]),

  ("B7_ctl_write_never_reaches_the_bus", "/ (the request half)",
     "              awv     <= 1'b1;\n"
     "              wv      <= 1'b1;\n"
     "              state   <= S_WR;",
     "              awv     <= 1'b0;\n"
     "              wv      <= 1'b0;\n"
     "              state   <= S_ANS;",
     ["test_ns38_write_low_half_reaches_ctl"]),
]

def run(rtl, testcase, tag):
    env = dict(os.environ)
    env["SIM_BUILD"] = tag
    env["TESTCASE"] = testcase
    p = subprocess.run(["make", f"BRG_SRC={rtl}"], cwd=HERE, env=env,
                       capture_output=True, text=True, timeout=1800)
    out = p.stdout + p.stderr
    m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
    return (None if not m else (int(m.group(1)), int(m.group(2)), int(m.group(3)))), out

def main():
    src = open(RTL).read()
    scored = []
    for _, _, _, _, tests in MUTANTS:
        for t in tests:
            if t not in scored:
                scored.append(t)
    for t in scored:
        res, _ = run(RTL, t, "sb_ctrl")
        ok = res is not None and res[2] == 0 and res[1] >= 1
        print(f"CONTROL {t}: {'PASS' if ok else 'FAIL'} {res}", flush=True)
        if not ok:
            print(" CONTROL FAILED - a 'caught' mutant would be meaningless. Stopping.")
            return 2

    tmp = tempfile.mkdtemp(prefix="drpbrg_mut_")
    results = []
    for name, clause, find, repl, tests in MUTANTS:
        if src.count(find) != 1:
            print(f"MUTANT {name}:  ANCHOR NOT UNIQUE (count={src.count(find)}) - HARD ERROR, not "
                  f"a skip: a mutant whose anchor moved silently stops testing its clause.",
                  flush=True)
            results.append((name, clause, "ANCHOR"))
            continue
        path = os.path.join(tmp, f"{name}.sv")
        open(path, "w").write(src.replace(find, repl))
        caught = []
        for t in tests:
            res, _ = run(path, t, "sb_m_" + name[:10])
            failed = (res is None) or (res[2] > 0)
            print(f"MUTANT {name} vs {t}: {'CAUGHT' if failed else 'SURVIVED'} {res}", flush=True)
            if failed:
                caught.append(t)
        results.append((name, clause, "CAUGHT" if caught else "SURVIVED"))

    print("\n==== MUTATION SUMMARY ====")
    n = sum(1 for _, _, s in results if s == "CAUGHT")
    for name, clause, s in results:
        print(f"  {s:9s} {clause:38s} {name}")
    print(f"MUTATION RESULT: {'PASS' if n == len(results) else 'FAIL'} ({n}/{len(results)} caught)")
    return 0 if n == len(results) else 1

if __name__ == "__main__":
    sys.exit(main())
