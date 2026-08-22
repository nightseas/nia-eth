#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_dual_port_reset_sync.py
# Description : Checks the reset synchroniser of the two client configuration, where a
#               shared synchroniser would couple the clients.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
DEFAULT_FILE = os.path.join(RTL, "dcmac_phy_wrapper.sv")
SYNC_MODULE = "dcmac_sync2"
MIN_STAGES = 2
DEST_CLK = "axis_clk"

FAMILY = {
    "rx_datapath_reset":       ("rx_dp_reset_s", "rx"),
    "tx_datapath_reset":       ("tx_dp_reset_s", "tx"),
    "rx_datapath_reset_ports": ("rx_dp_ports_s", "rx"),
}
SYNC_BRANCH = "g_dprst_sync"
RAW_BRANCH = "g_dprst_raw"

sys.path.insert(0, HERE)
from gate_quad_readiness import strip_comments, find_instances

def branch_span(code, label):
    m = re.search(r"begin\s*:\s*" + re.escape(label) + r"\b", code)
    if not m:
        return None
    depth, i = 1, m.end()
    for t in re.finditer(r"\b(begin|end)\b", code[m.end():]):
        depth += 1 if t.group(1) == "begin" else -1
        if depth == 0:
            return (m.start(), m.end() + t.start())
        i = m.end() + t.end()
    return (m.start(), i)

def check(path=None, clients=2, verbose=True):
    path = path or DEFAULT_FILE
    n_total = n_bad = 0

    def ok(msg):
        nonlocal n_total
        n_total += 1
        if verbose:
            print("OK   " + msg)

    def bad(msg):
        nonlocal n_total, n_bad
        n_total += 1
        n_bad += 1
        print("BAD  " + msg)

    if not os.path.exists(path):
        print("BAD  file not found: %s" % path)
        print("TOTAL 1 BAD 1")
        return 1
    code = strip_comments(open(path).read())

    sync_span = branch_span(code, SYNC_BRANCH)
    raw_span = branch_span(code, RAW_BRANCH)
    if sync_span and re.search(r"if\s*\(\s*EN_DPRST_SYNC\s*!=\s*0\s*\)", code):
        ok("P1 the synchronised variant `%s` exists under `EN_DPRST_SYNC != 0`" % SYNC_BRANCH)
    else:
        bad("P1 no `%s` branch under `EN_DPRST_SYNC != 0`. 's synchroniser must be the "
            "parameterised variant, so the pre-N6 structure stays reachable as a control" % SYNC_BRANCH)
    if raw_span:
        raw_body = code[raw_span[0]:raw_span[1]]
        missing = [r for r, (s, _) in FAMILY.items()
                   if not re.search(r"assign\s+" + re.escape(s) + r"\s*=\s*" + re.escape(r),
                                    raw_body)]
        if not missing:
            ok("P1 the NEGATIVE CONTROL variant `%s` reproduces the pre-N6 structure for all %d rows "
               "(E-7/E-8/E-9) - so 'nothing functional changed' is falsifiable"
               % (RAW_BRANCH, len(FAMILY)))
        else:
            bad("P1 `%s` does not pass through %s.: `EN_DPRST_SYNC = 0` shall reproduce the "
                "pre-N6 structure BYTE-FOR-BYTE; a partial control is not a control"
                % (RAW_BRANCH, missing))
    else:
        bad("P1 no `%s` else-branch.  Without it `EN_DPRST_SYNC = 0` cannot reproduce the "
            "silicon-proven structure, and 's claim that the change is timing-only becomes "
            "untestable at any level" % RAW_BRANCH)

    insts = find_instances(code, SYNC_MODULE)
    body = code[sync_span[0]:sync_span[1]] if sync_span else ""

    owner = {}
    for raw, (syn, side) in sorted(FAMILY.items()):
        mine = [i for i in insts
                if re.search(r"\b" + re.escape(raw) + r"\b", i["conns"].get("din", ""))]
        if len(mine) != 1:
            bad("P2 `%s`: %d `%s` instance(s) capture it, need exactly 1.  Zero means the "
                "tx_clk -> seg_clk crossing E-7/E-8/E-9 is still open - an unsynchronised level "
                "that survives on silicon only because it is held %s"
                % (raw, len(mine), SYNC_MODULE, "100 ms (T_RXDP_MS)"))
            continue
        i = mine[0]
        owner[raw] = i
        try:
            nst = int(i["params"].get("STAGES", "-1"))
        except ValueError:
            nst = -1
        if nst >= MIN_STAGES:
            ok("P2 `%s` -> `%s` via `%s`, STAGES=%d" % (raw, syn, i["inst"], nst))
        else:
            bad("P2 `%s` via `%s`: STAGES=%s, need >= %d.  was 213 of 213 failing setup "
                "endpoints from a crossing of exactly this shape, and NO SIMULATION CAN SEE IT"
                % (raw, i["inst"], i["params"].get("STAGES"), MIN_STAGES))
        if i["conns"].get("clk", "") == DEST_CLK:
            ok("P2 `%s` is captured in the DESTINATION domain `%s` (= seg_clk)" % (i["inst"], DEST_CLK))
        else:
            bad("P2 `%s` is clocked by `%s`, not the destination `%s`. Synchronising in the SOURCE "
                "domain moves the crossing, it does not close it"
                % (i["inst"], i["conns"].get("clk"), DEST_CLK))
        if syn in i["conns"].get("dout", ""):
            ok("P2 `%s` drives `%s`" % (i["inst"], syn))
        else:
            bad("P2 `%s` does not drive `%s` - the consumers are then reading something else"
                % (i["inst"], syn))

    rx_names = [r for r, (s, sd) in FAMILY.items() if sd == "rx"] + \
               [s for _, (s, sd) in FAMILY.items() if sd == "rx"] + ["rx_dp_reset_stretched"]
    tx_names = [r for r, (s, sd) in FAMILY.items() if sd == "tx"] + \
               [s for _, (s, sd) in FAMILY.items() if sd == "tx"]
    rx_re = r"\b(?:" + "|".join(map(re.escape, rx_names)) + r")\b"
    tx_re = r"\b(?:" + "|".join(map(re.escape, tx_names)) + r")\b"

    for raw, i in sorted(owner.items()):
        din = i["conns"].get("din", "")
        mixed = re.search(rx_re, din) and re.search(tx_re, din)
        if mixed:
            bad("P3 `%s`.din = `%s` mixes the RX and TX families.  THE VENDOR EXDES DEFECT THIS "
                "PROGRAM ROOT-CAUSED WAS EXACTLY ONE SHARED BIT: both gtwiz datapath resets hung "
                "off the TX register bit, so a reset on one board dropped its own TX and "
                "un-aligned the partner - an intermittency that cost a hardware campaign "
                "" % (i["inst"], din))
        else:
            ok("P3 `%s`.din carries ONE family only: `%s`" % (i["inst"], din))

    combined = []
    for m in re.finditer(r"[^;\n]*[;,\n]", code):
        s = m.group(0)
        if re.search(rx_re, s) and re.search(tx_re, s) and re.search(r"[|&^]", s):
            combined.append(" ".join(s.split())[:150])
    if combined:
        bad("P3 %d expression(s) COMBINE the RX and TX datapath-reset families with a bitwise "
            "operator: %s.: they shall be on separate paths that are NEVER ORed."
            % (len(combined), " || ".join(combined)))
    else:
        ok("P3 no expression anywhere in the file joins an RX and a TX datapath-reset signal with "
           "`|`, `&` or `^` - the two paths are structurally separate")

    PINS = {"INTF0_rst_tx_datapath_in": ("tx", tx_re, rx_re),
            "INTF0_rst_rx_datapath_in": ("rx", rx_re, tx_re)}
    for pin, (side, want_re, wrong_re) in sorted(PINS.items()):
        conns = re.findall(r"\.\s*" + re.escape(pin) + r"\s*\(([^)]*(?:\([^)]*\)[^)]*)*)\)", code)
        if len(conns) != clients:
            bad("P4 `%s` is connected %d time(s), expected one per client (%d).  The vendor exdes "
                "left the RX datapath-reset port DANGLING - that is the same defect as a missing "
                "connection here" % (pin, len(conns), clients))
        for k, expr in enumerate(conns):
            e = " ".join(expr.split())
            if not re.search(want_re, e):
                bad("P4 `%s`[%d] = `%s` is not driven from the %s family" % (pin, k, e, side))
            elif re.search(wrong_re, e):
                bad("P4 `%s`[%d] = `%s` is ALSO driven from the other family.  One shared bit "
                    "is the vendor defect" % (pin, k, e))
            else:
                idx = re.findall(r"\[\s*(\d+)\s*\]", e)
                if idx and int(idx[0]) == k:
                    ok("P4 `%s`[%d] = `%s` - %s family, client index %d, its own quad only "
                       "(: per-quad IS per-client here, asserted not assumed)"
                       % (pin, k, e, side, k))
                elif idx:
                    bad("P4 `%s` on quad %d is driven by client %s's signal (`%s`).: a "
                        "re-align on one client must not perturb the other; this is a cross-client "
                        "reset with the structure left intact" % (pin, k, idx[0], e))
                else:
                    bad("P4 `%s`[%d] = `%s` carries no client index - the per-quad == per-client "
                        "equivalence cannot be established" % (pin, k, e))

    for raw in sorted(FAMILY):
        offenders = []
        for m in re.finditer(r"\b" + re.escape(raw) + r"\b", code):
            pos = m.start()
            if raw_span and raw_span[0] <= pos <= raw_span[1]:
                continue
            before = code[:pos]
            if re.search(r"input\s+wire[^;]*$", before.split(";")[-1]):
                continue
            pm = re.search(r"\.\s*([A-Za-z_]\w*)\s*\(\s*$", before[-400:])
            if pm and pm.group(1) == "din":
                continue
            offenders.append(code[:pos].count("\n") + 1)
        if offenders:
            bad("P5 `%s`: %d use(s) outside its own synchroniser `.din` and outside the `%s` "
                "control branch, at line(s) %s.  A raw asynchronous level reaching seg_clk logic "
                "directly is E-7/E-8/E-9 unfixed - the crossing that has been on silicon since the "
                "single-port image" % (raw, len(offenders), RAW_BRANCH, offenders))
        else:
            ok("P5 `%s`: no load outside its own `.din` (the `%s` control branch exempt, because "
               "it IS the control)" % (raw, RAW_BRANCH))

    print("FILE  %s" % path)
    print("TOTAL %d BAD %d" % (n_total, n_bad))
    return 1 if n_bad else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", default=None)
    ap.add_argument("--clients", type=int, default=2)
    a = ap.parse_args()
    return check(a.file, a.clients)

if __name__ == "__main__":
    sys.exit(main())
