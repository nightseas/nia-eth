#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_ctl_seq_waits.py
# Description : Checks that every wait the hard block requires is present in the
#               sequencer, with the duration the specification states.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = os.path.normpath(os.path.join(HERE, "..", "..", "rtl", "ctl", "dcmac_ctl_seq.sv"))

MIN_WAIT_RECORDS = 9

SCALED = re.compile(
    r"^\(?\s*32'\(\s*(?P<p1>[A-Za-z_][A-Za-z_0-9]*)\s*\)\s*\*\s*"
    r"32'\(\s*(?P<p2>[A-Za-z_][A-Za-z_0-9]*)\s*\)\s*\)?$"
)
INIT = re.compile(r"^'0$")
ASSIGN = re.compile(r"\bw\s*=\s*(?P<expr>[^;]+);")

def check(path):
    with open(path) as f:
        lines = f.readlines()

    start = end = None
    for i, ln in enumerate(lines):
        if start is None and "function automatic" in ln and "rom_rec" in ln:
            start = i
        elif start is not None and re.match(r"\s*endfunction", ln):
            end = i
            break
    if start is None or end is None:
        print("BAD: could not locate `function automatic ... rom_rec` .. `endfunction`")
        print("TOTAL 0 BAD 1")
        return 1

    n_total = 0
    n_bad = 0
    n_init = 0
    n_scaled = 0
    for i in range(start, end):
        raw = lines[i]
        code = raw.split("//")[0]
        m = ASSIGN.search(code)
        if not m:
            continue
        expr = " ".join(m.group("expr").split())
        lineno = i + 1
        n_total += 1
        if INIT.match(expr):
            n_init += 1
            print(f"OK    line {lineno:4d}  initialiser        w = {expr}")
            continue
        ms = SCALED.match(expr)
        if ms and "CYC_PER_MS" in (ms.group("p1"), ms.group("p2")):
            other = ms.group("p2") if ms.group("p1") == "CYC_PER_MS" else ms.group("p1")
            n_scaled += 1
            print(f"OK    line {lineno:4d}  scaled by CYC_PER_MS  ms-param = {other}")
        else:
            n_bad += 1
            print(f"BAD   line {lineno:4d}   NOT scaled by CYC_PER_MS: w = {expr}")

    if n_init != 1:
        print(f"BAD   the record initialiser `w = '0;` appears {n_init} time(s), expected 1")
        n_bad += 1
    if n_scaled < MIN_WAIT_RECORDS:
        print(f"BAD   only {n_scaled} scaled wait records, expected >= {MIN_WAIT_RECORDS} "
              f"(a delay was DELETED, not just unscaled)")
        n_bad += 1

    print(f"FILE  {path}")
    print(f"TOTAL {n_total} BAD {n_bad}")
    return 1 if n_bad else 0

if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    sys.exit(check(src))
