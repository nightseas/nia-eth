#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_reset_ownership.py
# Description : Checks that a reset is driven by the module that owns it and by nothing
#               else.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
RTL = HERE.parent.parent / "rtl"

MAC = RTL / "dcmac_mac_group.sv"
PORT = RTL / "dcmac_port.sv"
FSM = RTL / "ctl/dcmac_mac_ctl_fsm.sv"
CTL = RTL / "ctl" / "dcmac_link_ctl.sv"

RETIRED = ["esc_rx_dp_reset", "esc_rx_dp_ports", "esc_gt_rx_reset", "esc_gt_tx_reset",
           "sup_stage", "sup_fault_diag", "sup_up_events", "sup_dn_events", "esc_brup"]

results = []

def chk(name, ok, why):
    results.append((name, bool(ok), why))

def code_of(path):
    out = []
    for ln in path.read_text().splitlines():
        t = ln.split("//")[0]
        if t.strip():
            out.append(t)
    return "\n".join(out)

def assign_rhs(code, lhs):
    pat = re.compile(r"(?:assign\s+|wire\s*(?:\[[^\]]*\]\s*)?)" + re.escape(lhs) + r"\s*=(.*?);",
                     re.S)
    return " ".join(m.group(1) for m in pat.finditer(code))

mac = code_of(MAC)
port = code_of(PORT)
fsm = code_of(FSM)
ctl = code_of(CTL)

rx = assign_rhs(mac, "phy_rx_dp_reset")
chk("rx_two_owners_present", "p_rx_dp_reset" in rx and "seq_rx_dp_for_client" in rx,
    "RX reset must be driven by the port's FSM (recovery) AND bring-up's B4 (configuration)")
terms = [t.strip() for t in rx.replace("\n", " ").split("|") if t.strip()]
chk("rx_exactly_two_terms", len(terms) == 2,
    f"RX reset has {len(terms)} terms, expected exactly 2 - every extra term is an owner nobody "
    f"assigned: {terms}")

for name in RETIRED:
    where = [f.name for f, c in ((MAC, mac), (PORT, port), (FSM, fsm), (CTL, ctl)) if name in c]
    chk(f"retired_gone_{name}", not where,
        f"`{name}` was retired by owner ruling but still appears in code in {where}")

tx = assign_rhs(mac, "phy_tx_dp_reset")
tx_terms = [t.strip() for t in tx.replace("\n", " ").split("|") if t.strip()]
chk("tx_exactly_one_term", len(tx_terms) == 1 and "p_tx_dp_reset" in tx,
    f"TX reset must have exactly ONE owner, the host through the port. Found: {tx_terms}")
chk("fsm_has_no_tx_output", not re.search(r"output\s+\w*\s*tx_datapath_reset", fsm),
    "the FSM must have no TX datapath reset output at all - the reset-ownership table gives TX to "
    "the host alone, and an output would be a second owner waiting to be connected")

merged = assign_rhs(mac, "link_reset_req") + " ".join(
    re.findall(r"\.link_reset_req\s*\((.*?)\)", mac, re.S)) + " ".join(
    re.findall(r"\.host_link_reset_req\s*\((.*?)\)", mac, re.S))
chk("host_term_is_a_request", "host_rx_dp_req_gated" in merged,
  ": the host's CTL[3] term must be merged into `link_reset_req`, upstream of the FSM")
chk("host_term_not_on_the_pin", "host_rx_dp_req_gated" not in rx,
  ": the host's term must NOT appear in the reset net's expression. That is the construction "
    "the review deleted from the FSM, and a raw level on this path stopped the MAC clock family on "
  "")

chk("fsm_owns_the_group_mask",
    "rx_datapath_reset_ports" in fsm and ("ANCHOR" in fsm and "NPORTS" in fsm),
    "PG369 p112: the FSM must compute its own ANCHOR..ANCHOR+NPORTS-1 mask, so every port of the "
    "group asserts and releases on the same cycle. The 2026-07 harness defect violated this "
    "paragraph by resetting only the anchor, and it cost this program the '400G intermittency'")
chk("wrapper_computes_no_mask", "GRP_MASK" not in ctl,
    "`dcmac_link_ctl` must not compute a port-group mask any more: it drives no reset")

bad = [(n, w) for n, ok, w in results if not ok]
for n, ok, w in results:
    print(f"  {'OK  ' if ok else 'BAD '} {n}")
    if not ok:
        print(f"       {w}")
print(f"RESET_OWNERSHIP TOTAL {len(results)} BAD {len(bad)}")
sys.exit(1 if bad else 0)
