#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_seg_sum_saturation.py
# Description : Checks that a frame of the configured maximum length fits the segment counter of
#               the derived generator chain, and reports the headroom of the three frame segment
#               count accumulations without requiring it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
CHAIN = os.path.join(ROOT, "rtl", "pktgen_seg", "dcmac_seg_pktgen_chain.sv")
INSTRUMENT = os.path.join(ROOT, "rtl", "dcmac_seg_pktgen.sv")

ACCUMULATIONS = ("num_seg_in_pkt_1_0_pre", "num_seg_in_pkt_2_0_pre")

SEG_TERM = re.compile(r"num_seg_in_pkt\[(\d+)\]\[(\d+)\]")
SEG_INDEX = re.compile(r"num_seg_in_pkt\[(\d+)\](?!\[)")
PAIR_SUM = "sum_seg_in_pkt_1_0"


def read(path):
    with open(path) as f:
        return f.read()


def strip_comments(text):
    return "\n".join(line.split("//")[0] for line in text.splitlines())


def declared_width(text, name):
    m = re.search(r"^\s*(?:reg|logic|wire)\s+((?:\[[^\]]+\]\s*)+)" + re.escape(name) + r"\s*;",
                  text, re.M)
    if not m:
        return None
    ranges = re.findall(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", m.group(1))
    if not ranges:
        return None
    hi, lo = int(ranges[-1][0]), int(ranges[-1][1])
    return hi - lo + 1


def segment_bytes(text):
    m = re.search(r"num_seg_in_pkt\[i\]\s*<=\s*pkt_len_r\[i\]\[(\d+):(\d+)\]", text)
    if not m:
        return None
    return 1 << int(m.group(2))


def assignment(text, name):
    m = re.search(re.escape(name) + r"\s*<=\s*(.*?);", text, re.S)
    if not m:
        return None
    return " ".join(m.group(1).split())


def guarded_indices(expr):
    cond = expr.split("?")[0]
    guarded = {}
    for index, bit in SEG_TERM.findall(cond):
        guarded.setdefault(int(index), set()).add(int(bit))
    return guarded


def constituent_indices(expr):
    value = expr.split("?", 1)[1] if "?" in expr else expr
    indices = set()
    if PAIR_SUM in value:
        indices |= {0, 1}
    for index in SEG_INDEX.findall(value):
        indices.add(int(index))
    return indices


def ceiling_from_source(text):
    m = re.search(r"parameter\s+integer\s+LEN_MAX_HW\s*=\s*(\d+)", text)
    return int(m.group(1)) if m else None


def check(len_max_hw):
    chain = strip_comments(read(CHAIN))
    seg_b = segment_bytes(chain)
    if seg_b is None:
        print("BAD: could not read the segment size from the num_seg_in_pkt assignment")
        print("TOTAL 0 BAD 1")
        return 1

    count_width = declared_width(chain, "num_seg_in_pkt")
    if count_width is None:
        print("BAD: could not read the declared width of num_seg_in_pkt")
        print("TOTAL 0 BAD 1")
        return 1

    max_segments = math.ceil(len_max_hw / seg_b)
    print(f"LEN_MAX_HW {len_max_hw} B, segment {seg_b} B, so a frame is at most "
          f"{max_segments} segment(s)")
    print(f"num_seg_in_pkt is {count_width} bit(s) wide")

    total = 0
    bad = 0

    if max_segments >= (1 << count_width):
        print(f"BAD  num_seg_in_pkt holds {(1 << count_width) - 1} and a frame needs "
              f"{max_segments}")
        bad += 1
    total += 1

    for name in ACCUMULATIONS:
        expr = assignment(chain, name)
        if expr is None:
            print(f"BAD  {name}: no assignment found")
            total += 1
            bad += 1
            continue
        width = declared_width(chain, name)
        if width is None:
            print(f"BAD  {name}: no declaration found")
            total += 1
            bad += 1
            continue

        guarded = guarded_indices(expr)
        constituents = constituent_indices(expr)
        saturation_bits = {b for b in range(count_width) if (1 << b) >= (1 << count_width) >> 2}

        worst = 0
        unguarded = []
        for index in sorted(constituents):
            bits = guarded.get(index, set())
            if bits >= saturation_bits:
                worst += (1 << min(saturation_bits)) - 1
            else:
                worst += max_segments
                unguarded.append(index)

        total += 1
        limit = (1 << width) - 1
        if unguarded:
            print(f"     {name}: constituent(s) {unguarded} are not saturated on bit(s) "
                  f"{sorted(saturation_bits)}")
        if worst > limit:
            print(f"NOTE {name}: {width} bit(s) hold {limit} and the largest value the guard "
                  f"admits is {worst}, over constituent(s) {sorted(constituents)}. Reachability "
                  f"is unproven and completing the guard is measured harmful: "
                  f"NIA_SYSTEM_DEV_PLAN.md Section 11.5")
        else:
            print(f"OK   {name}: {width} bit(s) hold {limit} and the largest value the guard "
                  f"admits is {worst}, over constituent(s) {sorted(constituents)}")

    print(f"TOTAL {total} BAD {bad}")
    return 1 if bad else 0


def main():
    override = None
    if len(sys.argv) > 1:
        override = int(sys.argv[1])
    elif os.environ.get("LEN_MAX_HW"):
        override = int(os.environ["LEN_MAX_HW"])
    len_max_hw = override if override is not None else ceiling_from_source(read(INSTRUMENT))
    if len_max_hw is None:
        print("BAD: could not read LEN_MAX_HW from rtl/dcmac_seg_pktgen.sv")
        print("TOTAL 0 BAD 1")
        return 1
    return check(len_max_hw)


if __name__ == "__main__":
    sys.exit(main())
