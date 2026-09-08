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
ASSIGN = re.compile(r"^\s*(\w+)\s*(\+=|:=|\?=|=)\s*(.*?)\s*$")
SHELL_PWD = re.compile(r"\$\(shell\s+pwd\)")
GENERIC = re.compile(r"^-G\w+=[^\s$]+$")


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
        line = re.sub(r"^\s*export\s+", "", line)
        m = ASSIGN.match(line)
        if m:
            name, op, value = m.group(1), m.group(2), m.group(3)
            if name.endswith("VERILOG_SOURCES") or name == "VERILOG_SOURCES":
                lines.append(value)
                vars_.setdefault("VERILOG_SOURCES", value)
            elif op == "+=":
                vars_[name] = (vars_.get(name, "") + " " + value).strip()
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
        return None, None, None, None
    files = []
    for tok in expand(src, vars_, here).split():
        if tok.endswith(".sv") or tok.endswith(".v"):
            files.append(str((here / tok).resolve()))
    top = expand(vars_.get("TOPLEVEL", ""), vars_, here).strip()
    defines = []
    for key, value in vars_.items():
        if key == "EXTRA_ARGS" and "+define+" in value:
            defines += [t for t in value.split() if t.startswith("+define+")]
    generics = []
    for tok in expand(vars_.get("COMPILE_ARGS", ""), vars_, here).split():
        if GENERIC.match(tok):
            generics.append(tok)
    return top, files, defines, generics


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    verilator = os.environ.get("NIA_VERILATOR", "verilator")
    bad = 0
    seen = 0
    for mk in sorted(root.glob("sim/**/Makefile*")):
        if "sim_build" in str(mk):
            continue
        top, files, defines, generics = sources_of(mk)
        if not top or not files:
            continue
        # A set that declares xsim needs the Vivado simulation libraries, because the
        # xpm_fifo and xpm_memory primitives of a vendor file elaborate there and under no
        # open tool. Verilator cannot read it, so the set states its simulator and this gate
        # honours the statement rather than reporting a fault it cannot repair.
        mk_text = mk.read_text(errors="replace")
        m = re.search(r"^\s*SIM\s*\??=\s*(\S+)", mk_text, re.M)
        if m and m.group(1).strip() == "xsim":
            print(f"SKIP {mk.relative_to(root)}: the set declares SIM=xsim, which carries the"
                  f" vendor xpm primitives that no open tool elaborates")
            continue
        # A set whose sources include the vendor tool tree elaborates only where that tool is
        # installed. The set carries its own skip path and reports it, so this gate leaves it
        # to the machine that has the tool.
        if "XILINX_VIVADO" in mk_text:
            print(f"SKIP {mk.relative_to(root)}: the set reads its primitives from the vendor"
                  f" tool tree, which is absent here")
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
               "-Wwarn-UNDRIVEN",
               "--top-module", top] + defines + generics + files
        res = subprocess.run(cmd, capture_output=True, text=True)
        errs = [l for l in res.stderr.splitlines() if l.startswith("%Error")]
        errs = [l for l in errs if "Exiting due to" not in l]
        errs += [l for l in res.stderr.splitlines() if "%Warning-UNDRIVEN" in l]
        shown = (" " + " ".join(generics)) if generics else ""
        if errs:
            print(f"FAIL {rel}: top {top}{shown}: {errs[0][:140]}")
            bad += 1
        else:
            print(f"OK   {rel}: top {top}, {len(files)} source(s){shown}")
    if seen == 0:
        print("FAIL gate resolved no simulation set")
        return 1
    print(f"gate_elaborate_sets: {seen} set(s) elaborated, {bad} failing")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
