#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_reset_gate_mutations.py
# Description : The mutation gate of the transceiver reset request gate.
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
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "gt_rst_req_gate.sv"))

MUTANTS = [
  ("M1_oneshot_becomes_the_raw_level", "  (the  defect itself)",
     "  assign req_pulse      = (EN_GATE != 0) ? pulse_r : req_level;",
     "  assign req_pulse      = req_level;",
     ["test_ns41_pulse_width_is_independent_of_the_host",
      "test_ns41_held_level_gives_exactly_one_pulse"], "CAUGHT"),

  ("M2_level_triggered_instead_of_edge", " half 1 of 2 - EQUIVALENT, see M12",
     "  wire req_rise  = req_level & ~req_1d;",
     "  wire req_rise  = req_level;",
     ["test_ns41_held_level_gives_exactly_one_pulse"], "EQUIVALENT"),

  ("M3_rearm_without_a_write_to_zero", " half 2 of 2 - EQUIVALENT, see M12",
     "      if (!req_level) arm_r <= 1'b1;",
     "      arm_r <= 1'b1;",
     ["test_ns41_held_level_gives_exactly_one_pulse"], "EQUIVALENT"),

  ("M12_both_oneshot_mechanisms_removed", "  (edge detect AND arm latch, TOGETHER)",
     [("  wire req_rise  = req_level & ~req_1d;", "  wire req_rise  = req_level;"),
      ("      if (!req_level) arm_r <= 1'b1;",    "      arm_r <= 1'b1;")],
     None,
     ["test_ns41_held_level_gives_exactly_one_pulse"], "CAUGHT"),

  ("M4_interlock_drops_reset_done", "  (PG442 p.16, in the vendor's own words)",
     "  wire allow     = done_q & ~seq_busy & ~stuck_r;",
     "  wire allow     = ~seq_busy & ~stuck_r;",
     ["test_ns42_refused_while_reset_done_low"], "CAUGHT"),

  ("M5_interlock_drops_seq_busy", "  (the monitor and the host fight)",
     "  wire allow     = done_q & ~seq_busy & ~stuck_r;",
     "  wire allow     = done_q & ~stuck_r;",
     ["test_ns42_refused_while_seq_busy"], "CAUGHT"),

  ("M6_holdoff_is_a_fixed_delay", "  (the 4th-injection death)",
     "          if (done_rise) begin\n"
     "            cnt_r   <= CW'(SETTLE_CYC - 1);\n"
     "            state_r <= S_HOLD;",
     "          if (1'b1) begin\n"
     "            cnt_r   <= CW'(SETTLE_CYC - 1);\n"
     "            state_r <= S_HOLD;",
     ["test_ns43_holdoff_waits_for_done_to_return"], "CAUGHT"),

  ("M7_timeout_never_latches_stuck", "  (the silent brick)",
     "            stuck_r <= 1'b1;                     // 200 ms with no `done` => report, do not retry",
     "            stuck_r <= 1'b0;",
     ["test_ns43_stuck_is_latched_and_no_further_pulse_is_issued"], "CAUGHT"),

  ("M8_stuck_does_not_block_further_pulses", " (report AND refuse)",
     "  wire allow     = done_q & ~seq_busy & ~stuck_r;",
     "  wire allow     = done_q & ~seq_busy;",
     ["test_ns43_stuck_is_latched_and_no_further_pulse_is_issued"], "CAUGHT"),

  ("M9_refusal_is_silent", "  (a dropped request with no counter)",
     "              refused_r <= 1'b1;\n"
     "              if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;\n"
     "            end\n"
     "          end\n"
     "        end\n"
     "        // ------------------------------------------------------------------------------------\n"
     "        S_PULSE: begin",
     "              refused_r <= 1'b0;\n"
     "            end\n"
     "          end\n"
     "        end\n"
     "        // ------------------------------------------------------------------------------------\n"
     "        S_PULSE: begin",
     ["test_ns42_refused_while_reset_done_low"], "CAUGHT"),

  ("M10_counter_wraps_instead_of_saturating", " (a wrapped count reads as zero)",
     "      if (clr_status) begin\n"
     "        stuck_r   <= 1'b0;\n"
     "        refused_r <= 1'b0;\n"
     "        rcnt_r    <= 4'd0;\n"
     "      end",
     "      if (clr_status) begin\n"
     "        stuck_r   <= 1'b0;\n"
     "        refused_r <= 1'b0;\n"
     "      end",
     ["test_ns45_refusals_are_counted_and_clearable"], "CAUGHT"),

  ("M11_midpulse_request_is_queued", "  (refuse, never queue)",
     "          if (want) begin\n"
     "            arm_r     <= 1'b0;\n"
     "            refused_r <= 1'b1;\n"
     "            if (rcnt_r != 4'hF) rcnt_r <= rcnt_r + 4'd1;\n"
     "          end\n"
     "        end\n"
     "        // ------------------------------------------------------------------------------------\n"
     "        S_WAITD: begin",
     "          if (want) begin\n"
     "            arm_r     <= 1'b0;\n"
     "            pulse_r   <= 1'b1;\n"
     "            cnt_r     <= CW'(PULSE_CYC - 1);\n"
     "          end\n"
     "        end\n"
     "        // ------------------------------------------------------------------------------------\n"
     "        S_WAITD: begin",
     ["test_ns42_a_refusal_is_dropped_not_queued"], "CAUGHT"),
]

def run(rtl, testcase, tag, en_gate=1):
    env = dict(os.environ)
    env["SIM_BUILD"] = tag
    env["TESTCASE"] = testcase
    p = subprocess.run(["make", "GATE_SRC=%s" % rtl, "EN_GATE=%d" % en_gate],
                       cwd=HERE, env=env, capture_output=True, text=True, timeout=1800)
    out = p.stdout + p.stderr
    m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
    return (None if not m else (int(m.group(1)), int(m.group(2)), int(m.group(3)))), out

def main():
    src = open(RTL).read()
    scored = []
    for entry in MUTANTS:
        for t in entry[4]:
            if t not in scored:
                scored.append(t)

    for t in scored:
        res, out = run(RTL, t, "sb_ctrl")
        ok = res is not None and res[2] == 0 and res[1] >= 1
        print("CONTROL %s: %s %s" % (t, "PASS" if ok else "FAIL", res), flush=True)
        if not ok:
            print(" CONTROL FAILED - a 'caught' mutant would be meaningless. Stopping.")
            print(out[-2000:])
            return 2

    tmp = tempfile.mkdtemp(prefix="dprst_mut_")
    results = []
    for i, entry in enumerate(MUTANTS):
        name, clause, find, repl, tests, expect = entry
        edits = find if isinstance(find, list) else [(find, repl)]
        mutated = src
        anchor_bad = None
        for f, r in edits:
            if mutated.count(f) != 1:
                anchor_bad = (f, mutated.count(f))
                break
            mutated = mutated.replace(f, r)
        if anchor_bad:
            print("MUTANT %s:  ANCHOR NOT UNIQUE (count=%d) - HARD ERROR, not a skip: a mutant "
                  "whose anchor moved silently stops testing its clause."
                  % (name, anchor_bad[1]), flush=True)
            results.append((name, clause, "ANCHOR", expect))
            continue
        path = os.path.join(tmp, "%s.sv" % name)
        open(path, "w").write(mutated)
        caught = []
        for t in tests:
            res, _ = run(path, t, "sb_m%02d" % i)
            failed = (res is None) or (res[2] > 0)
            print("MUTANT %s vs %s: %s %s (expected %s)"
                  % (name, t, "CAUGHT" if failed else "SURVIVED", res, expect), flush=True)
            if failed:
                caught.append(t)
        results.append((name, clause, "CAUGHT" if caught else "SURVIVED", expect))

    print("\n==== MUTATION SUMMARY ====")
    want_of = {"CAUGHT": "CAUGHT", "EQUIVALENT": "SURVIVED"}
    ok = 0
    for name, clause, got, expect in results:
        agree = (got == want_of.get(expect, expect))
        if agree:
            ok += 1
        print("  %-9s (want %-9s) %-12s %-46s %s"
              % (got, expect, "as expected" if agree else " MISMATCH", clause, name))
    print("   EQUIVALENT means: this single edit is NOT observable, because the property it "
          "attacks is enforced twice over. M12 removes both halves and MUST be caught.")
    print("MUTATION RESULT: %s (%d/%d as expected)"
          % ("PASS" if ok == len(results) else "FAIL", ok, len(results)))
    return 0 if ok == len(results) else 1

if __name__ == "__main__":
    sys.exit(main())
