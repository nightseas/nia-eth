#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_image_source_selection.py
# Description : Checks that the source list build_image.tcl selects for each pktgen, rate and
#               client count defines every module the selected top reaches, so a configuration
#               cannot reach synthesis with a module of ours missing from the list.
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
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
TCL = os.path.join(ROOT, "example", "TU03", "fpga", "build_image.tcl")
FILE_LIST = os.path.join(ROOT, "rtl", "dcmac_seam_files.f")
TOP_RTL = os.path.join(ROOT, "example", "TU03", "fpga", "rtl")

ANCHORS = {
    "clients": r'set clients \[expr \{\$rate == 400 \? 1 : 2\}\]',
    "seam_section": r'lappend sections \[expr \{\$top eq "tu03_axispg_top" \? "TOP_SEAM" : "TOP_SEAM_DUAL"\}\]',
    "inner_top": r'if \{\$pktgen eq "axis"\} \{\s*\n\s*lappend sources \[file normalize \[file join \$nia_root example TU03 fpga rtl fpga_axispg_dual_top\.sv\]\]\s*\n\s*\} elseif \{\$rate == 100\} \{',
    "board_top": r'lappend sources \[file normalize \[file join \$nia_root example TU03 fpga rtl \$rate_top_file\]\]',
}

# Keyed by the configuration, which is the rate except at 200G where the electrical lane
# count also selects: NIA_GAUI 2 is 200GAUI-2 and NIA_GAUI 4 is 200GAUI-4.
# A 200GAUI-4 client is one quad and four GT channels, the same geometry as 200GAUI-2, so the
# two share a PHY section and differ in the transceiver preset of the IP alone.
RATE_PHY_SECTION = {(100, 1): "PHY_REAL", (200, 2): "PHY_RATE200",
                    (200, 4): "PHY_RATE200", (400, 4): "PHY_RATE400"}

KEYWORDS = set("""if else for while case casez casex endcase module endmodule begin end always
always_ff always_comb always_latch assign initial final function endfunction task endtask generate
endgenerate wire reg logic input output inout parameter localparam typedef struct union enum return
posedge negedge unique unique0 priority default genvar integer int bit byte shortint longint real
shortreal string automatic static const signed unsigned void property endproperty assert assume
cover expect sequence endsequence clocking endclocking interface endinterface package endpackage
import export extern virtual pure context disable wait fork join join_any join_none repeat forever
do break continue force release deassign defparam specify endspecify table endtable primitive
endprimitive config endconfig class endclass extends implements new this super null randcase
randsequence constraint rand randc solve before with inside dist type ref var alias bind checker
endchecker covergroup endgroup coverpoint cross binsof intersect throughout first_match within
until iff matches tagged untagged celldefine endcelldefine timescale include define ifdef ifndef
endif elsif undef line""".split())

MODULE_RE = re.compile(r"^[ \t]*module[ \t]+([A-Za-z_][\w$]*)", re.M)
INST_RE = re.compile(
    r"^[ \t]*([A-Za-z_][\w$]*)[ \t]*(?:#[ \t]*\((?:[^;]*?)\)[ \t]*)?([A-Za-z_][\w$]*)[ \t]*\(",
    re.M | re.S)


def strip_code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = "\n".join(line.split("//")[0] for line in text.splitlines())
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)


def read_sections(path):
    sections = {}
    current = None
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                current = line.strip("[]")
                sections.setdefault(current, [])
                continue
            if current is not None:
                sections[current].append(line)
    return sections


def repo_sv_files():
    found = []
    for base in (os.path.join(ROOT, "rtl"), TOP_RTL):
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in filenames:
                if name.endswith(".sv"):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def index_repo():
    defined_by = {}
    instantiates = {}
    for path in repo_sv_files():
        code = strip_code(open(path, errors="replace").read())
        for mod in MODULE_RE.findall(code):
            defined_by.setdefault(mod, path)
        names = set()
        for type_name, inst_name in INST_RE.findall(code):
            if type_name in KEYWORDS or inst_name in KEYWORDS:
                continue
            names.add(type_name)
        instantiates[path] = names
    return defined_by, instantiates


def selection(pktgen, rate, gaui, clients, sections_by_name):
    phy = RATE_PHY_SECTION[(rate, gaui)]
    if rate == 100:
        if pktgen == "axis":
            top = "tu03_axispg_dual_top" if clients > 1 else "tu03_axispg_top"
        else:
            top = "tu03_pktgen_dual_top" if clients > 1 else "tu03_pktgen_board_top"
    elif rate == 200:
        top = "tu03_axispg_dual_top" if pktgen == "axis" else "tu03_pktgen_dual200_top"
    else:
        top = "tu03_axispg_dual_top" if pktgen == "axis" else "tu03_pktgen_400g_top"

    if pktgen == "axis":
        names = ["COMMON", "FIFO_IP", "PKTGEN_AXIS", phy, "OPTIONAL"]
        names.append("TOP_SEAM" if top == "tu03_axispg_top" else "TOP_SEAM_DUAL")
    else:
        names = ["COMMON", "PKTGEN", "TOP_PKTGEN", phy, "OPTIONAL"]
        if clients > 1:
            names.append("TOP_PKTGEN_DUAL")

    files = []
    for name in names:
        for rel in sections_by_name.get(name, []):
            files.append(os.path.normpath(os.path.join(ROOT, "rtl", rel)))
    if pktgen == "axis":
        files.append(os.path.join(TOP_RTL, "fpga_axispg_dual_top.sv"))
    elif rate == 100:
        files.append(os.path.join(TOP_RTL, "fpga_pktgen_top.sv"))
    files.append(os.path.join(TOP_RTL, top + ".sv"))
    return top, files


def missing_modules(top, files, defined_by, instantiates):
    provided = {}
    for path in files:
        code = strip_code(open(path, errors="replace").read()) if os.path.exists(path) else ""
        for mod in MODULE_RE.findall(code):
            provided[mod] = path
    missing = []
    seen = set()
    queue = [top]
    while queue:
        mod = queue.pop()
        if mod in seen:
            continue
        seen.add(mod)
        path = provided.get(mod)
        if path is None:
            if mod in defined_by:
                missing.append((mod, defined_by[mod]))
            continue
        for name in sorted(instantiates.get(path, ())):
            if name in defined_by and name not in seen:
                queue.append(name)
    return missing


def configurations():
    for pktgen in ("axis", "seg"):
        for rate, gaui in ((100, 1), (200, 2), (400, 4)):
            clients = 1 if rate == 400 else 2
            yield pktgen, rate, gaui, clients
    # 200GAUI-4 wires 16 serial pins, which only the AXI-Stream top carries.
    yield "axis", 200, 4, 2
    yield "axis", 100, 1, 1
    yield "seg", 100, 1, 1


def main():
    problems = 0
    checks = 0

    tcl = open(TCL).read()
    for name, pattern in ANCHORS.items():
        if re.search(pattern, tcl) is None:
            print("BAD anchor %s is absent from %s, so this gate no longer models the script"
                  % (name, os.path.relpath(TCL, ROOT)))
            problems += 1
        checks += 1

    sections_by_name = read_sections(FILE_LIST)
    defined_by, instantiates = index_repo()

    for pktgen, rate, gaui, clients in configurations():
        top, files = selection(pktgen, rate, gaui, clients, sections_by_name)
        checks += 1
        absent = [f for f in files if not os.path.exists(f)]
        if absent:
            print("BAD pktgen=%s rate=%d gaui=%d clients=%d names a file that is absent: %s"
                  % (pktgen, rate, gaui, clients,
                     ", ".join(os.path.relpath(f, ROOT) for f in absent)))
            problems += 1
            continue
        missing = missing_modules(top, files, defined_by, instantiates)
        if missing:
            for mod, path in missing:
                print("BAD pktgen=%s rate=%d gaui=%d clients=%d top=%s: module %s is reached and "
                      "is defined by %s, which the selected source list does not carry"
                      % (pktgen, rate, gaui, clients, top, mod, os.path.relpath(path, ROOT)))
            problems += len(missing)
        else:
            print("OK  pktgen=%-4s rate=%-3d gaui=%d clients=%d top=%-24s sources=%d"
                  % (pktgen, rate, gaui, clients, top, len(files)))

    print("TOTAL %d BAD %d" % (checks, problems))
    if problems:
        print("IMAGE SOURCE SELECTION RESULT: FAIL")
        return 1
    print("IMAGE SOURCE SELECTION RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
