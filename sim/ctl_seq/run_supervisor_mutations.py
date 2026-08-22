#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_supervisor_mutations.py
# Description : The mutation gate of the link supervisor check, run as a control and a
#               mutant pair.
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
WDT = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_link_wdt.sv"))
CTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_link_ctl.sv"))
CSR = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "dcmac_link_csr.sv"))

MUTANTS = [
  ("M1_escalation_stops_after_two_windows", "", WDT, "Makefile.wdt", "WDT_SRC",
     [("                2'd1: begin rxdp_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E1_HOLD; end",
       "                2'd1: begin rxdp_r <= (escn_r < 16'd2); tmr <= rxdp_cyc; st <= S_E1_HOLD; end"),
      ("              escn_r  <= (escn_r == 16'hFFFF) ? escn_r : escn_r + 16'd1;",
       "              escn_r  <= (escn_r >= 16'd2) ? escn_r : escn_r + 16'd1;")],
     ["test_ns54_escalates_every_window_forever"], []),

  ("M2_the_watchdog_never_expires", "", WDT, "Makefile.wdt", "WDT_SRC",
     [("        S_WINDOW: begin\n          if (tmr <= 1) begin",
       "        S_WINDOW: begin\n          if (1'b0) begin")],
     ["test_ns54_escalates_every_window_forever"], []),

  ("M3_a_long_outage_latches_the_supervisor_off", "", WDT, "Makefile.wdt", "WDT_SRC",
     [("          if (poll_gnt) req_r <= 1'b0;   // the executor took it; drop the level",
       "          if (poll_gnt) req_r <= 1'b0;\n          if (escn_r > 16'd3) st <= S_OFF;")],
     ["test_ns55_no_state_stops_and_a_late_link_is_taken"], []),

  ("M4_one_poll_verdict_register_shared_between_groups", "", CTL, "Makefile.link_ctl", "CTL_SRC",
     [("      assign link_up  [g] = sup_seen_r[g] ? sup_up[g]   : seq_link_up[g];\n"
       "      assign link_live[g] = sup_seen_r[g] ? sup_live[g] : seq_link_up[g];",
       "      assign link_up  [g] = sup_seen_r[0] ? sup_up[0]   : seq_link_up[0];\n"
       "      assign link_live[g] = sup_seen_r[0] ? sup_live[0] : seq_link_up[0];")],
     ["test_ns56_a_group_in_escalation_does_not_freeze_its_sibling"], ["stage2"]),

  ("M5_escalation_drives_the_SIBLING_clients_ports", "/", CTL, "Makefile.link_ctl", "CTL_SRC",
     [("      assign esc_rx_dp_ports[g*PORT_MAX +: PORT_MAX] = esc_rx_dp_reset[g] ? GRP_MASK : '0;",
       "      assign esc_rx_dp_ports[g*PORT_MAX +: PORT_MAX] = esc_rx_dp_reset[g] ? "
       "((PORT_MAX)'((1 << (NPORTS*2)) - 1)) : '0;")],
     ["test_ns58_tx_precedes_rx_and_the_mask_is_the_group"], []),

  ("M6_TX_and_RX_share_one_bit", "/", WDT, "Makefile.link_ctl", "WDT_SRC",
     [("            gtrx_r <= 1'b1;",
       "            gtrx_r <= 1'b1; gttx_r <= 1'b1;")],
     ["test_ns58_tx_precedes_rx_and_the_mask_is_the_group"], ["stage2"]),

  ("M7_TX_half_triggered_by_RX_alignment_loss_alone", "", WDT, "Makefile.wdt", "WDT_SRC",
     [("                2'd1: begin rxdp_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E1_HOLD; end",
       "                2'd1: begin gttx_r <= 1'b1; tmr <= rxdp_cyc; st <= S_E2_TX;   end")],
     ["test_ns58_esc_max_stage_1_is_the_rx_only_control"], ["rxonly"]),

  ("M8_one_port_of_a_group_released_early", "/PG369p112", CTL, "Makefile.link_ctl", "CTL_SRC",
     [("          ((PORT_MAX)'((1 << NPORTS) - 1)) << anch_of(g);",
       "          ((PORT_MAX)'(1)) << anch_of(g);")],
     ["test_ns58_tx_precedes_rx_and_the_mask_is_the_group"], ["wide"]),

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

  ("M12_the_rise_is_also_debounced", "", WDT, "Makefile.wdt", "WDT_SRC",
     [("              if (!up_r) begin\n                up_r   <= 1'b1;",
       "              if (!up_r && cfm_reached) begin\n                up_r   <= 1'b1;")],
     ["test_ns61_rise_publishes_on_the_first_aligned_poll"], []),
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
    sources = {WDT: open(WDT).read(), CTL: open(CTL).read(), CSR: open(CSR).read()}

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
