#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_instrument_elab.py
# Description : Elaborates the whole AXI-Stream instrument at every supported rate, against
#               the PHY stub and the FIFO models, and requires no error and no width or
#               connection warning that is not in instrument_elab_baseline.json. It is the
#               check that sees the wiring the rate knob selects, which no per set
#               elaboration does because each set instantiates one geometry.
#
#               The baseline exists because dcmac_axis_dual_top declares its transmit,
#               completion and status ports two clients wide whatever N_CLIENT is, so at
#               RATE 400 with one client verilator reports 25 truncations that are correct
#               by construction: only slice 0 is driven and only slice 0 is read. Narrowing
#               those ports is an open item; until then the baseline is what keeps a new
#               mismatch from hiding among them.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RTL = os.path.join(ROOT, "rtl")
TOP_RTL = os.path.join(ROOT, "example", "TU03", "fpga", "rtl")
LIST = os.path.join(RTL, "dcmac_seam_files.f")
BASELINE = os.path.join(HERE, "instrument_elab_baseline.json")

# Each entry is a configuration name, the rate and the electrical lane count of one
# client. 200GAUI-4 shares the rate and the stream geometry of 200GAUI-2 and differs in
# the serial pin count, so it is elaborated as its own set.
CONFIGS = (("100", 100, 1), ("200", 200, 2), ("200g4", 200, 4), ("400", 400, 4))
SECTIONS = ["COMMON", "FIFO_MODEL", "PKTGEN_AXIS", "PHY_STUB", "OPTIONAL", "TOP_SEAM_DUAL"]


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
    """One entry per warning, keyed on kind, file and the identifiers it names, so an entry
    survives a line move but not a change of signal."""
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
        print("INSTRUMENT ELAB SKIPPED: verilator is not on PATH")
        return 0

    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}

    files = [os.path.normpath(os.path.join(RTL, rel)) for rel in sections(LIST, SECTIONS)]
    files.append(os.path.join(TOP_RTL, "fpga_axispg_dual_top.sv"))
    missing = [f for f in files if not os.path.exists(f)]
    if missing:
        for f in missing:
            print(f"BAD  source absent: {f}")
        print(f"TOTAL {len(CONFIGS)} BAD {len(CONFIGS)}")
        print("INSTRUMENT ELAB RESULT: FAIL")
        return 1

    bad = 0
    for name, rate, gaui in CONFIGS:
        data_w = 512 if rate == 100 else 1024
        gt_lanes = 16 if (rate == 200 and gaui == 4) else 8
        work = os.path.join(HERE, f"obj_instr_{name}")
        shutil.rmtree(work, ignore_errors=True)
        cmd = [vl, "--lint-only", "-Wno-fatal", "--timing",
               "--top-module", "fpga_axispg_dual_top", "-Mdir", work,
               f"-GRATE={rate}", f"-GGAUI={gaui}", f"-GGT_LANES={gt_lanes}",
               f"-GDATA_W={data_w}",
               "-GLEN_MIN_HW=64", "-GLEN_MAX_HW=9018"] + files
        r = subprocess.run(cmd, capture_output=True, text=True)
        text = r.stdout + r.stderr
        shutil.rmtree(work, ignore_errors=True)

        seen = normalise(text)
        known = set(baseline.get(name, []))
        new = sorted(seen - known)
        errs = sorted(e for e in seen if e.startswith("Error"))
        if new or errs:
            bad += 1
            print(f"BAD  RATE={rate} GAUI={gaui} DATA_W={data_w} GT_LANES={gt_lanes}: {len(new)} "
                  f"new, {len(errs)} error(s), {len(seen)} total against a baseline of {len(known)}")
            for e in (errs + new)[:20]:
                print(f"       {e}")
        else:
            print(f"OK   RATE={rate} GAUI={gaui} DATA_W={data_w} GT_LANES={gt_lanes} elaborated, "
                  f"{len(files)} source(s), {len(seen)} baselined warning(s), 0 new")

    print(f"TOTAL {len(CONFIGS)} BAD {bad}")
    print("INSTRUMENT ELAB RESULT: " + ("PASS" if bad == 0 else "FAIL"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
