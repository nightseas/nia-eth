#!/usr/bin/env python3
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RTL = os.path.join(ROOT, "rtl")
LIST = os.path.join(RTL, "dcmac_seam_files.f")
SECTIONS = ["COMMON", "FIFO_MODEL", "PHY_STUB", "OPTIONAL", "TOP_SEAM"]

CONFIGS = (
    ("100GAUI-1_one_client", {
        "N_SEG": "2", "DATA_W": "512", "NPORTS": "1", "ANCHOR": "0",
        "RATE_CODE": "0", "RATE_FIELD": "4", "DONE_MASK": "8'h03",
        "POLARITY_TX_Q0": "8'b0000_0000", "POLARITY_RX_Q0": "8'b0000_0000"}),
    ("200GAUI-2_one_client", {
        "N_SEG": "4", "DATA_W": "1024", "NPORTS": "2", "ANCHOR": "0",
        "RATE_CODE": "1", "RATE_FIELD": "8", "DONE_MASK": "8'h0f",
        "POLARITY_TX_Q0": "8'b0000_1100", "POLARITY_RX_Q0": "8'b0000_0000"}),
    ("200GAUI-2_one_client_512", {
        "N_SEG": "4", "DATA_W": "512", "NPORTS": "2", "ANCHOR": "0",
        "RATE_CODE": "1", "RATE_FIELD": "8", "DONE_MASK": "8'h0f",
        "POLARITY_TX_Q0": "8'b0000_1100", "POLARITY_RX_Q0": "8'b0000_0000"}),
)

def sections(path, wanted):
    out, cur = [], None
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            cur = line.strip("[]")
            continue
        if cur in wanted:
            out.append(line)
    return out

def normalise(text):
    out = set()
    for line in text.splitlines():
        m = re.match(r"^%(Error\S*|Warning-\w+):\s+([^:]+):\d+:\d+:\s*(.*)$", line)
        if not m:
            continue
        kind, path, msg = m.group(1), os.path.basename(m.group(2)), m.group(3)
        ids = re.findall(r"'([^']+)'", msg)
        out.add(f"{kind} {path} {'|'.join(ids)}")
    return out

def main():
    vl = shutil.which("verilator")
    if vl is None:
        print("AXIS TOP RATE ELAB SKIPPED: verilator is not on PATH")
        return 0

    files = [os.path.normpath(os.path.join(RTL, rel)) for rel in sections(LIST, SECTIONS)]
    missing = [f for f in files if not os.path.exists(f)]
    if missing:
        for f in missing:
            print(f"BAD  source absent: {f}")
        print(f"TOTAL {len(CONFIGS)} BAD {len(CONFIGS)}")
        print("AXIS TOP RATE ELAB RESULT: FAIL")
        return 1

    bad = 0
    for name, generics in CONFIGS:
        work = os.path.join(HERE, f"obj_axis_top_{name}")
        shutil.rmtree(work, ignore_errors=True)
        cmd = [vl, "--lint-only", "-Wno-fatal", "--timing",
               "--top-module", "dcmac_axis_top", "-Mdir", work]
        cmd += [f"-G{k}={v}" for k, v in generics.items()]
        cmd += files
        r = subprocess.run(cmd, capture_output=True, text=True)
        text = r.stdout + r.stderr
        shutil.rmtree(work, ignore_errors=True)

        seen = sorted(normalise(text))
        shown = " ".join(f"{k}={v}" for k, v in generics.items())
        if seen:
            bad += 1
            print(f"BAD  {name}: {len(seen)} error(s) or warning(s)")
            print(f"       {shown}")
            for e in seen[:20]:
                print(f"       {e}")
        else:
            print(f"OK   {name} elaborated clean, {len(files)} source(s): {shown}")

    print(f"TOTAL {len(CONFIGS)} BAD {bad}")
    print("AXIS TOP RATE ELAB RESULT: " + ("PASS" if bad == 0 else "FAIL"))
    return 0 if bad == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
