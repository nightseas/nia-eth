#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : run_mutations.py
# Description : The mutation gate of the adapter: applies each declared mutant, requires
#               the named test to fail, and refuses to score if the unmutated tree does
#               not pass first.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import hashlib
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))

sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..")))
from nia_rtl_lock import rtl_lock, nia_rtl_root
LOGDIR = os.environ.get("LOGDIR", os.path.join(HERE, "logs"))

BASE = {"SEED": "1", "TX_MHZ": "250", "RX_MHZ": "250"}
PTP = dict(BASE, PTP_TS_EN="1", TX_TAG_W="16")

MUTANTS = [
    ("M1", "dcmac_seg_axis_rx.sv",
     "          slot_load_next[write_slot_next] = 1'b1;",
     "          slot_load_next[write_slot_next] = (lane == 0);",
     "RX stores every segment except lane 0 nowhere, so a segment is lost",
     ["test_rx_byte_exact"], BASE),
    ("M2", "dcmac_seg_axis_adapter.sv",
     "      slot_mty_c[j]  = MTY_W'(SEG_B) - MTY_W'($countones(keep_slot));",
     "      slot_mty_c[j]  = MTY_W'(SEG_B) - MTY_W'($countones(keep_slot)) + MTY_W'(1);",
     "TX last-beat byte count off by one (corrupt tkeep/mty on EOP)",
     ["test_tx_byte_exact"], BASE),
    ("M3", "ctl/dcmac_mac_ctl_fsm.sv",
     "    tx_rst_r <= ~seg_rstn | (state != S_XFER) | ~stat_rx_aligned;",
     "    tx_rst_r <= 1'b0;",
     "reset handshake broken: tx_rst released before the link is up",
     ["test_bringup_sequence"], BASE),
    ("M4", "dcmac_axis_adapter.sv",
     "  wire tx_gate = ctl_tx_enable | tx_in_frame;",
     "  wire tx_gate = 1'b1;",
     "TX gate removed: frames leave before ctl_tx_enable",
     ["test_tx_gated_before_enable"], BASE),
    ("M6", "dcmac_axis_frame_fifo.sv",
     "    assign m_axis_tvalid = (rd_ptr != wr_commit);",
     "    assign m_axis_tvalid = (rd_ptr != wr_cur);",
     "store-and-forward defeated (a plain FIFO):  gaplessness lost",
     ["test_tx_gapless"], BASE),

    ("M7", "dcmac_axis_rx_stream.sv",
     "    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1),",
     "    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b0), .DROP_WHEN_FULL(1'b1),",
  ": the RX frame FIFO stops re-pointing the frame-scoped error onto the "
     "emitted tuser.  MEASURED, and it corrected this entry: the error-at-EOP case STILL "
     "WORKS without FLAG_BAD_FRAME, because eth_axis_dwidth_up's flush already ORs the "
     "error onto the tlast beat when the error IS at EOP. FLAG_BAD_FRAME is load-bearing "
  "ONLY for the mid-frame case - which is exactly 's case. Distinguished "
     "from M8 by NOT touching TX",
     ["test_rx_err_midframe_flagged_on_tlast"], BASE),
    ("M8", "dcmac_axis_frame_fifo.sv",
     "  wire frame_err = s_axis_tuser[0] | err_seen;",
     "  wire frame_err = s_axis_tuser[0];",
  "  /  restored: the error flag becomes beat-scoped again, so an error "
     "flagged before the final AXIS beat never reaches the tlast beat. MUST fail ONLY the "
     "mid-frame test - error-at-EOP still works and the core's counter is separate",
     ["test_rx_err_midframe_flagged_on_tlast"], BASE),

    ("M9", "dcmac_axis_rx_stream.sv",
     "    else if (rxa_tvalid && rxa_tlast && (rxa_tuser | rxa_err_seen) &&",
     "    else if (rxa_tvalid && rxa_tlast && rxa_tuser &&",
  " restored in the counter: a mid-frame RX error is not counted (X6)",
     ["test_rx_err_midframe_counted"], BASE),
    ("M10", "dcmac_axis_frame_fifo.sv",
     "          if (full)          drop_frame <= 1'b1;",
     "          if (full)          drop_frame <= 1'b0;",
  " defeated: beats are skipped mid-frame (wr_store is gated by ~full) and the frame "
     "is committed TRUNCATED, so a partial frame reaches the core and can fuse onto the next",
     ["test_rx_frames_whole_under_slow_rxclk"], BASE),

    ("M11", "dcmac_axis_adapter.sv",
  "    .s_axis_tuser  (s_axis_tx_tuser),",
  "    .s_axis_tuser  ({TX_USER_W{1'b0}}),",
  "  defeated by restoring EXACTLY the line dcmac_axis_core.sv:428 had: the TX "
     "user field is tied to zero, so a frame abort can never reach the MAC. This is the "
     "defect the native seam exists to fix, and it is one character deep",
     ["test_tx_abort_maps_to_seg_err"], BASE),
    ("M12", "dcmac_axis_rx_stream.sv",
     "    else if (rx_sop) rx_ts_hold <= seg_ptp_time;",
     "    else if (rxa_tvalid && rxa_tlast) rx_ts_hold <= seg_ptp_time;",
  ": the RX PTP timestamp is captured at EOP instead of at SOP, so it describes "
     "when the frame ENDED. Only visible in the PTP variant",
     ["test_rx_ptp_ts_field"], PTP),
    ("M13", "dcmac_axis_adapter.sv",
     "    rx_rst_seg <= ~seg_rstn | ~link_up_i | ~stat_rx_aligned_seg;",
     "    rx_rst_seg <= 1'b0;",
  ": rx_rst never asserts, so the NIC core's RX logic is released before the MAC "
     "can deliver anything (mqnic_port.v:220 takes this as an input)",
     ["test_rxrst_latency"], BASE),
    ("M14", "dcmac_axis_adapter.sv",
     "    rx_sts_s0 <= link_up_i;",
     "    rx_sts_s0 <= 1'b1;",
  ": rx_status is stuck high, so the core believes the link is usable while it "
     "is down (this reverses 's 'no status at the seam' in the wrong direction)",
     ["test_mac_status_exported"], BASE),
    ("M15", "dcmac_axis_adapter.sv",
     "      .s_axis_tvalid (tx_eop_accepted),",
     "      .s_axis_tvalid (1'b0),",
  ": no TX completion is ever generated, so a PTP tag never returns to the core. "
     "Only visible in the PTP/tag variant",
     ["test_tx_cpl_tag_roundtrip"], PTP),
    ("M16", "dcmac_axis_rx_stream.sv",
  "    .m_axis_tready (1'b1),",
  "    .m_axis_tready (1'b0),",
  ": the push-only RX drain is stopped, so nothing is ever delivered. This proves "
     "the tie-off is load-bearing and not decoration",
     ["test_rx_byte_exact"], BASE),
    ("M17", "dcmac_seg_axis_rx.sv",
     "                      || sop_with_frame_open;",
     "                      || 1'b0;",
     "a segment arriving with every beat group already full is absorbed silently instead of "
     "being reported in rx_align_drop",
     ["test_rx_sop_with_partial_assembly_is_reported"], BASE),
    ("M20", "dcmac_seg_axis_rx.sv",
     "    valid_bytes = SEG_KEEP_W - int'(empty_bytes);",
     "    valid_bytes = SEG_KEEP_W - int'(empty_bytes) + 1;",
     "the final segment keeps one byte more than it carries, so a frame is delivered a byte "
     "too long",
     ["test_rx_byte_exact"], BASE),
    ("M18", "dcmac_seg_axis_rx.sv",
     "        slot_data[slot] <= segment_data_d2[slot_lane_d1[slot]];",
     "        slot_data[slot] <= segment_data_d1[slot_lane_d1[slot]];",
     "the slot takes its lane select one pipeline stage early, so the slot holds the segment "
     "of a neighbouring lane",
     ["test_rx_byte_exact"], BASE),
    ("M19", "dcmac_seg_axis_rx.sv",
     "        if (group_filled_d1[group])      group_ready[group] <= 1'b1;",
     "        if (group_filled_next[group])    group_ready[group] <= 1'b1;",
     "a beat group is offered one cycle before its slots are written, which is the hazard the "
     "second registration exists to remove",
     ["test_rx_packed_byte_exact"], BASE),
]

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def run_suite(tag, mkvars):
    os.makedirs(LOGDIR, exist_ok=True)
    xml = os.path.join(LOGDIR, f"results_mut_{tag}.xml")
    log = os.path.join(LOGDIR, f"mut_{tag}.log")
    subprocess.run(["make", "-s", "clean"], cwd=HERE, capture_output=True)
    argv = ["make"] + [f"{k}={v}" for k, v in mkvars.items()] + \
           [f"COCOTB_RESULTS_FILE={xml}"]
    with open(log, "w") as fh:
        fh.write("# " + " ".join(argv) + "\n")
        fh.flush()
        subprocess.run(argv, cwd=HERE, stdout=fh, stderr=subprocess.STDOUT)
    try:
        root = ET.parse(xml).getroot()
    except Exception as e:
        return None, None, f"no/unparsable XML ({e})", log
    tcs = list(root.iter("testcase"))
    failed = [c.get("name") for c in tcs if len(list(c))]
    return len(tcs), failed, None, log

def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None

    stale = []
    for mid, fname, old, _new, _what, _expect, _env in MUTANTS:
        path = os.path.join(RTL, fname)
        if not os.path.exists(path):
            stale.append((mid, fname, "file missing"))
        elif old not in open(path).read():
            stale.append((mid, fname, "anchor not found"))
    if stale:
        print("ANCHOR PRE-FLIGHT FAILED - these mutants cannot be applied:")
        for mid, fname, why in stale:
            print(f"  {mid}: {fname}: {why}")
        print("\nMUTATION RESULT: FAIL (stale harness, not necessarily broken RTL)")
        return 2
    print(f"anchor pre-flight OK: {len(MUTANTS)} mutants applicable")

    base_arms = {}
    for _mid, _f, _o, _n, _w, _e, env in MUTANTS:
        key = tuple(sorted(env.items()))
        base_arms[key] = env
    for key, env in base_arms.items():
        tag = "base_" + "_".join(f"{k}{v}" for k, v in sorted(env.items())
                                if k not in ("SEED",))
        n, failed, err, log = run_suite(tag, env)
        print(f"BASELINE {env}: tests={n} failed={failed} err={err}  log={log}")
        if err is not None or failed:
            print("\nMUTATION RESULT: FAIL (a baseline variant is already red; fix that first)")
            return 3

    rows = []
    with rtl_lock(nia_rtl_root(__file__), who=f"run_mutations.py ({only or 'all'})"):
      for mid, fname, old, new, what, expect, env in MUTANTS:
        if only and mid != only:
            continue
        path = os.path.join(RTL, fname)
        orig = open(path).read()
        orig_md5 = md5(path)
        assert old in orig, f"{mid}: anchor not found in {fname}"
        open(path, "w").write(orig.replace(old, new, 1))
        assert md5(path) != orig_md5, f"{mid}: mutation did not change the file"
        try:
            n, failed, err, log = run_suite(mid, env)
        finally:
            open(path, "w").write(orig)
            assert md5(path) == orig_md5, f"{mid}: FAILED TO REVERT {fname}"
        caught = err is None and failed is not None and \
            all(any(e in f for f in failed) for e in expect) and len(failed) > 0
        rows.append((mid, fname, what, expect, n, failed, err, caught, log))
        print(f"{mid}: tests={n} failed={failed} err={err} caught={caught}")

    print("\n| mutant | file | injected defect | expected to fail | observed | caught |")
    print("|---|---|---|---|---|---|")
    ok = True
    for mid, fname, what, expect, n, failed, err, caught, log in rows:
        obs = err if err else f"TESTS={n} FAIL={len(failed)}: {', '.join(failed) or 'none'}"
        print(f"| {mid} | `{fname}` | {what} | {', '.join(expect)} | {obs} | "
              f"{'YES' if caught else 'NO'} |")
        ok &= caught
    print(f"\nMUTATION RESULT: {'PASS (every mutant caught)' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
