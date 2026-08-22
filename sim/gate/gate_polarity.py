#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_polarity.py
# Description : Checks the lane polarity tables against the ports they set, and proves the
#               check is not vacuous by mutating a copy.
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
import shutil
import subprocess
import sys
import tempfile

POL_TX = {"202": [0, 0, 1, 1], "203": [1, 1, 0, 0], "204": [1, 1, 0, 0], "205": [1, 1, 0, 0]}
POL_RX = {"202": [0, 0, 0, 0], "203": [1, 1, 1, 1], "204": [1, 1, 0, 0], "205": [1, 1, 1, 1]}

CAGE = [("Q0", "QSFP0", "202"), ("Q1", "QSFP1", "204")]

def norm(t):
    return re.sub(r"\s+", " ", t)

def check(dcm, out=print):
    bad = 0
    pkg_p = os.path.join(dcm, "ctl", "dcmac_ctl_pkg.sv")
    phy_p = os.path.join(dcm, "dcmac_phy_wrapper.sv")
    stub_p = os.path.join(dcm, "dcmac_phy_model.sv")

    for p in (pkg_p, phy_p, stub_p):
        if not os.path.isfile(p):
            out("NS28 FAIL missing artifact: %s" % p)
            bad += 1
    if bad:
        return bad

    pkg = open(pkg_p).read()
    phy = open(phy_p).read()
    stub = open(stub_p).read()
    phyn = norm(phy)

    for q, cage, bank in CAGE:
        for dr, tab in (("TX", POL_TX), ("RX", POL_RX)):
            key = "%s_%sPOLARITY" % (cage, dr)
            m = re.search(key + r"\s*=\s*8'b([01_]+)", pkg)
            if not m:
                out("NS28 FAIL C3 %s is ABSENT from dcmac_ctl_pkg.sv, so %s.CH0's board fact has "
                    "no source of truth and that lane would build at the gtwiz default of 0."
                    % (key, bank))
                bad += 1
                continue
            bits = m.group(1).replace("_", "")
            got = bits[-1]
            got1 = bits[-2] if len(bits) > 1 else "0"
            exp = str(tab[bank][0])
            ok = got == exp
            out("NS28 %s C3 %-16s = %-11s CH0=%s CH1=%s expect CH0=%s (%s.CH0)"
                % ("ok  " if ok else "FAIL", key, m.group(1), got, got1, exp, bank))
            if not ok:
                bad += 1
            if got1 != got:
                out("NS28 FAIL C3 %s: CH1 (%s) != CH0 (%s). CH1 is CH0's Dual partner and its "
                    "polarity input is inert, but it must be set equal - lib_polarity.tcl:29-31."
                    % (key, got1, got))
                bad += 1

    for q, cage, bank in CAGE:
        for dr in ("TX", "RX"):
            par = "POLARITY_%s_%s" % (dr, q)
            src = "%s_%sPOLARITY" % (cage, dr)
            ok = re.search(par + r"\s*=\s*dcmac_ctl_pkg::" + src, phy) is not None
            out("NS28 %s C4 %s defaults from dcmac_ctl_pkg::%s"
                % ("ok  " if ok else "FAIL", par, src))
            if not ok:
                bad += 1

    for q, cage, bank in CAGE:
        for conn in (".INTF0_TX0_ch_txpolarity (POLARITY_TX_%s[0])" % q,
                     ".INTF0_TX1_ch_txpolarity (POLARITY_TX_%s[1])" % q,
                     ".INTF0_RX0_ch_rxpolarity (POLARITY_RX_%s[0])" % q,
                     ".INTF0_RX1_ch_rxpolarity (POLARITY_RX_%s[1])" % q):
            ok = conn in phyn
            out("NS28 %s C5 %s/bank%s %s" % ("ok  " if ok else "FAIL", cage, bank, conn))
            if not ok:
                bad += 1
    n_tx, n_rx = phy.count("ch_txpolarity"), phy.count("ch_rxpolarity")
    out("NS28 info C5 phy refs: txpolarity=%d rxpolarity=%d (want >= 4 each: TX0+TX1 x 2 quads)"
        % (n_tx, n_rx))
    if n_tx < 4 or n_rx < 4:
        bad += 1

    for pat, what in ((r"POLARITY_TX_Q1\[1:0\]\s*!=\s*2'b11", "the 204.CH0 TX_INV=1 $fatal"),
                      (r"POLARITY_RX_Q1\[1:0\]\s*!=\s*2'b11", "the 204.CH0 RX_INV=1 $fatal")):
        ok = re.search(pat, phy) is not None
        out("NS28 %s C5b %s is present in dcmac_phy_wrapper.sv"
            % ("ok  " if ok else "FAIL", what))
        if not ok:
            bad += 1

    for q, _, _ in CAGE:
        for dr in ("TX", "RX"):
            par = "POLARITY_%s_%s" % (dr, q)
            ok = re.search(r"parameter\s+logic\s*\[7:0\]\s+" + par, stub) is not None
            out("NS28 %s C6 dcmac_phy_model.sv declares parameter %s"
                % ("ok  " if ok else "FAIL", par))
            if not ok:
                bad += 1

    out("NS28 VERDICT bad=%d  (L3 - do the gtwiz ports EXIST - is Vivado-only: "
        "synth/dcmac_polarity.tcl checks C1/C2)" % bad)
    return bad

MUTANTS = [
    ("M1_pkg_qsfp1_zero", "ctl/dcmac_ctl_pkg.sv",
     r"QSFP1_TXPOLARITY = 8'b0000_0011", "QSFP1_TXPOLARITY = 8'b0000_0000"),
    ("M2_drop_quad1_tx0_conn", "dcmac_phy_wrapper.sv",
     ".INTF0_TX0_ch_txpolarity   (POLARITY_TX_Q1[0]),", "// mutant: connection deleted"),
    ("M3_default_not_from_pkg", "dcmac_phy_wrapper.sv",
     "POLARITY_TX_Q1         = dcmac_ctl_pkg::QSFP1_TXPOLARITY",
     "POLARITY_TX_Q1         = 8'b0000_0011"),
    ("M4_stub_param_removed", "dcmac_phy_model.sv",
     "parameter logic [7:0] POLARITY_RX_Q1 = dcmac_ctl_pkg::QSFP1_RXPOLARITY",
     "parameter int         MUTANT_PLACEHOLDER = 0"),
    ("M5_drop_elab_guard", "dcmac_phy_wrapper.sv",
     "POLARITY_TX_Q1[1:0] != 2'b11", "1'b0"),
    ("M6_ch1_differs_from_ch0", "ctl/dcmac_ctl_pkg.sv",
     r"QSFP1_RXPOLARITY = 8'b0000_0011", "QSFP1_RXPOLARITY = 8'b0000_0001"),
]

def selftest(dcm):
    base = check(dcm, out=lambda *a: None)
    print("SELFTEST baseline bad=%d %s" % (base, "(PASS)" if base == 0 else "(must be 0)"))
    if base != 0:
        print("SELFTEST ABORTED: the unmutated tree already fails; fix that first.")
        return 99
    caught = 0
    for name, rel, old, new in MUTANTS:
        with tempfile.TemporaryDirectory() as td:
            work = os.path.join(td, "dcmac")
            shutil.copytree(dcm, work,
                            ignore=shutil.ignore_patterns("sim*", "__pycache__", "*.xci", "ip"))
            p = os.path.join(work, rel)
            t = open(p).read()
            if t.count(old) < 1:
                print("SELFTEST %-24s ANCHOR MISS (%d hits of its anchor in %s) - the mutation "
                      "could not be applied, so it proves nothing. Fix the anchor."
                      % (name, t.count(old), rel))
                continue
            open(p, "w").write(t.replace(old, new, 1))
            bad = check(work, out=lambda *a: None)
            ok = bad > 0
            caught += 1 if ok else 0
            print("SELFTEST %-24s mutated %-26s bad=%d %s"
                  % (name, rel, bad, "CAUGHT" if ok else "ESCAPED"))
    print("SELFTEST TOTAL %d BAD %d" % (len(MUTANTS), len(MUTANTS) - caught))
    return 0 if caught == len(MUTANTS) else 99

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dcm", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        rc = selftest(a.dcm)
        print("RESULT: %s" % ("PASS" if rc == 0 else "FAIL"))
        return rc
    bad = check(a.dcm)
    print("RESULT: %s" % ("PASS" if bad == 0 else "FAIL"))
    return bad

if __name__ == "__main__":
    sys.exit(main())
