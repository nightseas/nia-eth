#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_param_overrides.py
# Description : Checks that every parameter override in every instantiation names a
#               parameter the instantiated module declares.
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

SKIP_PARTS = ("sim", "sim_ip", "sim_csr", "sim_drp", "tb", "lint", "fifo_model", "fifo_ip")

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

def files():
    for f in sorted(root.rglob("*.sv")):
        if not any(p in f.parts for p in SKIP_PARTS):
            yield f

declared = {}
for f in files():
    text = f.read_text(errors="ignore")
    for m in re.finditer(r"^\s*module\s+(\w+)\s*#\s*\((.*?)^\s*\)\s*\(", text, re.S | re.M):
        name, body = m.group(1), m.group(2)
        body = "\n".join(l.split("//")[0] for l in body.splitlines())
        declared[name] = set(re.findall(r"parameter\b[^=,;]*?(\w+)\s*=", body))

bad = []
for f in files():
    text = "\n".join(l.split("//")[0] for l in f.read_text(errors="ignore").splitlines())
    for m in re.finditer(r"\b(\w+)\s*#\s*\(([^;]*?)\)\s*(\w+)\s*\(", text, re.S):
        mod, plist = m.group(1), m.group(2)
        if mod not in declared:
            continue
        for pname in re.findall(r"\.\s*(\w+)\s*\(", plist):
            if pname not in declared[mod]:
                bad.append(f"{f.relative_to(root)}: .{pname}() -> module '{mod}' declares no such "
                           f"parameter")

if bad:
    print("FAIL")
    for b in bad[:10]:
        print("      " + b)
    sys.exit(1)
print(f"{len(declared)} modules, every override names a declared parameter  PASS")
