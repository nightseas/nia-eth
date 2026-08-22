#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_ctl_seq_groups.py
# Description : Checks that the sequencer's per group work is written per group, so a two
#               group build cannot inherit one group's writes.
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

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_ctl_seq.sv"))
WAITS_GATE = os.path.join(HERE, "gate_ctl_seq_waits.py")

EXPECTED_GROUP_SCALED = {
    "P_B5W":   "ends B5's per-group channel asserts       (5*NP*NG)",
    "P_B10":   "ends B9's per-group release               (2*NP*NG)",
    "P_B17":   "ends B11's per-group CHANNEL release      (2*NP*NG)",
    "P_STATS": "ends B17's per-group pmtick               (2*NP*NG)",
    "N_STAT":  "C16's per-group counter burst      (STATS_PER*NP*NG)",
}
MIN_GROUP_SCALED_SECTIONS = len(EXPECTED_GROUP_SCALED)

def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(ln.split("//")[0] for ln in text.splitlines())

def _func_body(code, name):
    m = re.search(r"function\s+automatic\s+[^\n]*\b" + re.escape(name) + r"\s*\(", code)
    if not m:
        return None
    end = code.find("endfunction", m.end())
    return code[m.end():end] if end > 0 else None

def check(path):
    if not os.path.exists(path):
        print(f"BAD  file not found: {path}")
        print("TOTAL 0 BAD 1")
        return 1
    text = open(path).read()
    code = _strip_comments(text)
    n_total = n_bad = 0

    def ok(m):
        nonlocal n_total
        n_total += 1
        print(f"OK   {m}")

    def bad(m):
        nonlocal n_total, n_bad
        n_total += 1
        n_bad += 1
        print(f"BAD  {m}")

    body = _func_body(code, "anch")
    if body is None:
        bad("S1: `function automatic int anch(...)` not found - the ONLY place group -> "
            "first-MAC-slot is decided is missing or renamed")
    else:
        b = " ".join(body.split())
        has0 = re.search(r"\bANCHOR\b", b) is not None
        has1 = re.search(r"\bANCHOR_1\b", b) is not None
        cond = re.search(r"\bg\b", b) is not None
        if has0 and has1 and cond:
            ok(f"S1 `anch()` selects on the group index and names both anchors: {b}")
        else:
            bad(f"S1 `anch()` = {b}   needs ANCHOR({has0}) ANCHOR_1({has1}) and a `g` "
                f"condition({cond}). Collapsing it deletes EVERY one of group 1's per-port "
                f"writes at a single stroke -  requires the ROM to program BOTH groups")

    body = _func_body(code, "is_anch")
    if body is None:
        bad("S2: `function automatic bit is_anch(...)` not found")
    else:
        b = " ".join(body.split())
        has0 = re.search(r"\bANCHOR\b", b) is not None
        has1 = re.search(r"\bANCHOR_1\b", b) is not None
        if has0 and has1:
            ok(f"S2 `is_anch()` names both anchors: {b}")
        else:
            bad(f"S2 `is_anch` = {b}  ANCHOR({has0}) ANCHOR_1({has1}).: the rate/field "
                f"words go to EVERY anchor. Only slot 0 programmed leaves the SECOND cage at "
                f"rate 0 - a link that never aligns and looks like silicon (cf. )")

    m = re.search(r"localparam\s+int\s+NG\s*=\s*([^;]+);", code)
    if not m:
        bad("S3: `localparam int NG` not found")
    else:
        rhs = " ".join(m.group(1).split())
        if re.search(r"\bN_GROUP\b", rhs):
            ok(f"S3 `NG` derives from the parameter: NG = {rhs}")
        else:
            bad(f"S3 `NG = {rhs}`   must derive from `N_GROUP`. A literal makes every "
                f"group-scoped section collapse while the parameter still reads 2, so the image "
                f"programs one port and reports two")

    scaled = []
    unscaled = []
    for m in re.finditer(r"localparam\s+int\s+(P_[A-Z0-9_]+|N_STAT)\s*=\s*([^;]+);", code):
        name, rhs = m.group(1), " ".join(m.group(2).split())
        if not re.search(r"\bNP\b", rhs):
            continue
        if re.search(r"\bNG\b", rhs):
            scaled.append((name, rhs))
        else:
            unscaled.append((name, rhs))
    for name, rhs in scaled:
        ok(f"S4 `{name}` is group-scaled: {rhs}")
    for name, rhs in unscaled:
        bad(f"S4 `{name}` = {rhs}   walks MAC ports (`NP`) but is NOT sized by `NG`, so group "
            f"1's records DO NOT EXIST.  Invisible at N_GROUP = 1, which is every "
            f"single-client variant")
    seen = {n for n, _ in scaled}
    for name, why in sorted(EXPECTED_GROUP_SCALED.items()):
        if name in seen:
            continue
        bad(f"S4 expected group-scaled section `{name}` ({why}) is ABSENT or no longer "
            f"group-scaled -  requires the ROM to program every per-port write for BOTH "
            f"slots, and this section is one of them")
    for name, _rhs in scaled:
        if name not in EXPECTED_GROUP_SCALED:
            print(f"INFO S4 `{name}` is group-scaled and NOT in this gate's expected set - "
                  f"probably a new section from `seam_n6`; re-read the set and record the md5")
    if len(scaled) < MIN_GROUP_SCALED_SECTIONS:
        bad(f"S4 only {len(scaled)} group-scaled per-port section(s), expected >= "
            f"{MIN_GROUP_SCALED_SECTIONS}")
    else:
        ok(f"S4 {len(scaled)} group-scaled per-port sections, all {len(EXPECTED_GROUP_SCALED)} "
           f"expected ones present")

    m = re.search(r"localparam\s+int\s+P_B17\s*=\s*([^;]+);", code)
    if not m:
        bad("S5: `localparam int P_B17` not found - the truncation is undeterminable")
    else:
        rhs = " ".join(m.group(1).split())
        if re.search(r"\bP_B11\b", rhs) and re.search(r"2\s*\*\s*NP\s*\*\s*NG", rhs):
            ok(f"S5 the poll removal was a truncation: P_B17 = {rhs}")
        else:
            bad(f"S5 `P_B17 = {rhs}`   B17 does not sit at `P_B11 + 2*NP*NG`. Removing the poll "
                f"block must be a TRUNCATION: every record before it keeps its address AND its "
                f"order, which is why the golden trace still passes unedited over B5..B11 "
                f". If this fails, the configuration program MOVED.")

    if not os.path.exists(WAITS_GATE):
        bad(f"S6: {WAITS_GATE} missing - the  class would be ungated")
    else:
        r = subprocess.run([sys.executable, WAITS_GATE, path], capture_output=True, text=True)
        tail = [ln for ln in r.stdout.strip().splitlines() if ln.startswith("TOTAL ")]
        if r.returncode == 0:
            ok(f"S6 gate_ctl_seq_waits.py passes ({tail[-1] if tail else 'no TOTAL line'}) - "
               f"every `w =` record is `* CYC_PER_MS` scaled")
        else:
            bad(f"S6 gate_ctl_seq_waits.py FAILS ({tail[-1] if tail else 'no TOTAL line'}) - a "
                f"wait is unscaled or deleted. That is 's class: it reached silicon "
                f"and is in the ARP-proven link")

    print(f"FILE  {path}")
    print(f"TOTAL {n_total} BAD {n_bad}")
    return 1 if n_bad else 0

if __name__ == "__main__":
    sys.exit(check(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC))
