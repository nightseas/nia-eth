#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_elaborate_sets.py
# Description : Elaborates every simulation set without running it, so a set that cannot
#               build is found before a dispatch.
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
from pathlib import Path

VAR = re.compile(r"\$\((\w+)\)")
ASSIGN = re.compile(r"^\s*(\w+)\s*(?::=|\?=|=)\s*(.*?)\s*$")
SHELL_PWD = re.compile(r"\$\(shell\s+pwd\)")


def parse_makefile(path):
    vars_ = {}
    lines = []
    raw = path.read_text().splitlines()
    joined = []
    buf = ""
    for line in raw:
        if line.rstrip().endswith("\\"):
            buf += line.rstrip()[:-1] + " "
            continue
        joined.append(buf + line)
        buf = ""
    if buf:
        joined.append(buf)
    for line in joined:
        if line.lstrip().startswith("#"):
            continue
        m = ASSIGN.match(line)
        if m:
            name, value = m.group(1), m.group(2)
            if name.endswith("VERILOG_SOURCES") or name == "VERILOG_SOURCES":
                lines.append(value)
                vars_.setdefault("VERILOG_SOURCES", value)
            else:
                vars_[name] = value
    return vars_


def expand(value, vars_, here):
    prev = None
    out = SHELL_PWD.sub(str(here), value)
    while out != prev:
        prev = out
        out = SHELL_PWD.sub(str(here), out)
        for name in VAR.findall(out):
            repl = vars_.get(name)
            if repl is None:
                repl = os.environ.get(name, "")
            repl = SHELL_PWD.sub(str(here), repl)
            out = out.replace(f"$({name})", repl)
    return out


def sources_of(path):
    here = path.parent.resolve()
    vars_ = parse_makefile(path)
    for name in ("HERE", "PWD", "THIS_DIR", "MK_DIR", "SIM_DIR_SELF"):
        vars_[name] = str(here)
    src = vars_.get("VERILOG_SOURCES", "")
    if not src:
        return None, None, None
    files = []
    for tok in expand(src, vars_, here).split():
        if tok.endswith(".sv") or tok.endswith(".v"):
            files.append(str((here / tok).resolve()))
    top = expand(vars_.get("TOPLEVEL", ""), vars_, here).strip()
    defines = []
    for key, value in vars_.items():
        if key == "EXTRA_ARGS" and "+define+" in value:
            defines += [t for t in value.split() if t.startswith("+define+")]
    return top, files, defines


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    verilator = os.environ.get("NIA_VERILATOR", "verilator")
    bad = 0
    seen = 0
    for mk in sorted(root.glob("sim/**/Makefile*")):
        if "sim_build" in str(mk):
            continue
        top, files, defines = sources_of(mk)
        if not top or not files:
            continue
        seen += 1
        missing = [f for f in files if not Path(f).exists()]
        rel = mk.relative_to(root)
        if missing:
            print(f"FAIL {rel}: {len(missing)} source(s) missing: {missing[0]}")
            bad += 1
            continue
        cmd = [verilator, "--lint-only", "-sv", "-Wno-TIMESCALEMOD", "-Wno-WIDTH",
               "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-UNOPTFLAT",
               "-Wno-CASEINCOMPLETE", "-Wno-MULTIDRIVEN", "-Wno-SELRANGE",
               "--top-module", top] + defines + files
        res = subprocess.run(cmd, capture_output=True, text=True)
        errs = [l for l in res.stderr.splitlines() if l.startswith("%Error")]
        errs = [l for l in errs if "Exiting due to" not in l]
        if errs:
            print(f"FAIL {rel}: top {top}: {errs[0][:140]}")
            bad += 1
        else:
            print(f"OK   {rel}: top {top}, {len(files)} source(s)")
    if seen == 0:
        print("FAIL gate resolved no simulation set")
        return 1
    print(f"gate_elaborate_sets: {seen} set(s) elaborated, {bad} failing")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
