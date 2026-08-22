#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : check_sources.py
# Description : The structural check behind make check. Every path a source list or a
#               build script names must exist, and a variable the script cannot resolve is
#               reported rather than skipped.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import pathlib
import re
import sys

SRC_EXT = (".v", ".sv", ".vh", ".svh", ".xdc", ".c", ".h", ".tcl")

SET = re.compile(r'^[ \t]*set[ \t]+(\w+)[ \t]+(.*)$')
REF = re.compile(r'\$(?:\{(\w+)\}|(\w+))((?:/[\w.\-]+)+)')
ENV_TERNARY = re.compile(
    r'\[info exists ::env\((\w+)\)\]\s*\?\s*\$::env\(\w+\)\s*:\s*"([^"]+)"')

def strip_comment(s):
    i = s.find(";#")
    return (s[:i] if i >= 0 else s).strip()

def matching(s, start):
    depth = 0
    for i in range(start, len(s)):
        if s[i] == "[":
            depth += 1
        elif s[i] == "]":
            depth -= 1
            if depth == 0:
                return i
    return -1

def expand(text, vars_):
    out = []
    i = 0
    while i < len(text):
        if text[i] == "$":
            m = re.match(r'\$\{(\w+)\}|\$(\w+)', text[i:])
            if m:
                name = m.group(1) or m.group(2)
                if name not in vars_ or vars_[name] is None:
                    return None
                out.append(vars_[name])
                i += m.end()
                continue
        out.append(text[i])
        i += 1
    return "".join(out)

def value(expr, vars_, script):
    expr = strip_comment(expr)
    if expr.startswith("["):
        end = matching(expr, 0)
        if end < 0:
            return None
        inner = expr[1:end].strip()
        if inner.startswith("info script"):
            return str(script.resolve())
        if inner.startswith("file normalize"):
            v = value(inner[len("file normalize"):].strip(), vars_, script)
            if v is None:
                return None
            if not os.path.isabs(v):
                v = os.path.join(os.getcwd(), v)
            return os.path.normpath(v)
        if inner.startswith("file join"):
            parts = []
            for tok in inner[len("file join"):].split():
                v = value(tok, vars_, script)
                if v is None:
                    return None
                parts.append(v)
            if not parts:
                return None
            out = parts[0]
            for q in parts[1:]:
                out = os.path.join(out, q)
            return out
        if inner.startswith("file dirname"):
            v = value(inner[len("file dirname"):].strip(), vars_, script)
            return None if v is None else os.path.dirname(v)
        if inner.startswith("expr"):
            m = ENV_TERNARY.search(inner)
            if not m:
                return None
            env, default = m.groups()
            return os.environ.get(env) or expand(default, vars_)
        return None
    return expand(expr.strip('"'), vars_)

def script_vars(path):
    vars_ = {}
    for line in path.read_text(errors="replace").splitlines():
        m = SET.match(line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2)
        v = value(rhs, vars_, path)
        if v is not None:
            vars_[name] = v
    return vars_

def mount_roots(root):
    out = {}
    gm = root / ".gitmodules"
    if not gm.is_file():
        return out
    env = {"verilog-pcie": "NIA_VERILOG_PCIE", "eth": "NIA_ETH", "dpdk": "NIA_DPDK"}
    for line in gm.read_text().splitlines():
        line = line.strip()
        if not line.startswith("path"):
            continue
        p = line.split("=", 1)[1].strip()
        named = os.environ.get(env.get(p, ""), "")
        here = root / p
        content = [x for x in here.glob("*") if x.name != ".gitkeep"] if here.is_dir() else []
        if named and pathlib.Path(named).is_dir():
            out[p] = str(pathlib.Path(named).resolve())
        elif content:
            out[p] = str(here)
        else:
            out[p] = None
    return out

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    root = pathlib.Path(sys.argv[1]).resolve()
    mounts = mount_roots(root)
    missing = pending = total = 0
    unresolved = set()
    for arg in sys.argv[2:]:
        path = pathlib.Path(arg)
        if not path.is_file():
            print(f"  {arg}: not a file")
            missing += 1
            continue
        if path.suffix == ".f":
            base = path.parent
            named = set()
            for line in path.read_text(errors="replace").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or line.startswith("["):
                    continue
                if line.startswith("-") or line.startswith("+"):
                    continue
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                named.add(os.path.normpath(str(base / line)))
            for s_ in sorted(named):
                total += 1
                if os.path.exists(s_):
                    continue
                waiting = any(resolved is None and s_.startswith(str(root / p) + os.sep)
                              for p, resolved in mounts.items())
                if waiting: pending += 1
                else:
                    missing += 1
                    print(f"  {arg}: source missing: {s_}")
            continue
        vars_ = script_vars(path)
        named = set()
        for m in REF.finditer(path.read_text(errors="replace")):
            var = m.group(1) or m.group(2)
            tail = m.group(3)
            if not tail.endswith(SRC_EXT):
                continue
            if var not in vars_:
                unresolved.add(f"{arg}:${var}")
                continue
            named.add(os.path.normpath(vars_[var] + tail))
        for s in sorted(named):
            total += 1
            if os.path.exists(s):
                continue
            waiting = any(
                resolved is None and s.startswith(str(root / p) + os.sep)
                for p, resolved in mounts.items()
            )
            if waiting:
                pending += 1
            else:
                missing += 1
                print(f"  {arg}: source missing: {s}")
    for u in sorted(unresolved):
        print(f"  {u}: a variable this check cannot resolve, so its paths were not verified")
        missing += 1
    print(f"NIA_TCL {total} named, {missing} missing, {pending} awaiting a mount")
    return min(missing, 125)

if __name__ == "__main__":
    sys.exit(main())
