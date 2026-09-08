#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_stream_rate.py
# Description : Relates the host stream geometry to the line rate and refuses a
#               configuration that cannot carry it. A frame occupies whole stream beats and
#               its wire slot is its length plus 24 bytes, so the beat rate a rate demands
#               is a property of ports, width and clock alone. Nothing else in this
#               repository relates those three, which is how a one port 400G configuration
#               and a 250 MHz 1024 bit 200G configuration were both built without
#               objection.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python
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
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
INSTR = os.path.join(ROOT, "example", "TU03", "fpga", "rtl", "fpga_axispg_dual_top.sv")

# The wire slot of a frame is its length plus the 4 byte frame check sequence the MAC
# appends, 8 of preamble and 12 of interpacket gap.
SLOT_OVERHEAD = 24
LEN_MIN = 64
LEN_MAX = 9018
SEG_MHZ = 390.930          # the DCMAC segmented interface clock this repository constrains

# The configurations the flow may build. A row is line rate when its worst case fraction is
# 1.0; a row with a stated fraction is a declared fallback and the figure is the acceptance.
# RATE, N_STREAM, DATA_W, NET_MHZ, declared worst case fraction or None for line rate.
SUPPORTED = [
    (100, 1,  512, 250.000, 0.88),
    (100, 1,  512, 390.625, None),
    (200, 1, 1024, 250.000, 0.77),
    (200, 1, 1024, 390.625, None),
    (400, 2, 1024, 250.000, 0.77),
    (400, 2, 1024, 390.625, None),
]

# Configurations that shall be refused, with the reason, so the gate is not vacuous.
REFUSED = [
    (400, 1, 1024, 390.625, "one 1024 bit port carries 400.4 Gb/s of beats against a frame "
                            "rate that needs 653.6 M beats/s at 129 bytes"),
    (400, 1, 1024, 250.000, "one 1024 bit port carries 256.0 Gb/s against a 400 Gb/s wire, "
                            "so it is short at every frame size"),
]


def worst_fraction(rate_gbps, n_stream, data_w, net_mhz):
    """The smallest capacity over demand across every frame length, and the length at which
    it occurs. Capacity is beats per second; demand is beats per second the wire imposes."""
    beat_b = data_w // 8
    capacity = n_stream * net_mhz * 1e6
    wire_bps = rate_gbps * 1e9 / 8.0
    worst, worst_len = None, None
    for length in range(LEN_MIN, LEN_MAX + 1):
        frames = wire_bps / (length + SLOT_OVERHEAD)
        demand = frames * math.ceil(length / beat_b)
        f = capacity / demand
        if worst is None or f < worst:
            worst, worst_len = f, length
    return min(worst, 1.0), worst_len


def tx_bound(rate_gbps, n_seg):
    """One start of packet per segmented cycle is one frame per cycle, so the transmit side
    is line rate only at and above the length whose wire slot the segment clock can keep up
    with. Reported, not asserted: the transmit packing form is a separate open item."""
    wire_bps = rate_gbps * 1e9 / 8.0
    frames_avail = SEG_MHZ * 1e6
    length = wire_bps / frames_avail - SLOT_OVERHEAD
    return max(LEN_MIN, math.ceil(length))


def rtl_stream_count():
    """The N_STREAM the instrument derives, read out of the source so the table above cannot
    drift from the design."""
    text = open(INSTR).read()
    m = re.search(r"localparam int N_STREAM\s*=\s*\(RATE == 400\)\s*\?\s*(\d+)\s*:\s*(\d+);", text)
    if not m:
        return None
    return {400: int(m.group(1)), 200: int(m.group(2)), 100: int(m.group(2))}


def main():
    bad = 0
    total = 0

    derived = rtl_stream_count()
    if derived is None:
        print(f"BAD  {os.path.basename(INSTR)}: N_STREAM is not derived from RATE in the form "
              f"this gate reads, so the table cannot be checked against the design")
        bad += 1
    else:
        print(f"OK   {os.path.basename(INSTR)} derives N_STREAM " +
              ", ".join(f"{r}G->{n}" for r, n in sorted(derived.items())))

    for rate, n_stream, data_w, net_mhz, declared in SUPPORTED:
        total += 1
        frac, at_len = worst_fraction(rate, n_stream, data_w, net_mhz)
        txl = tx_bound(rate, {100: 2, 200: 4, 400: 8}[rate])
        tag = f"RATE={rate} {n_stream}x{data_w} @ {net_mhz:.3f} MHz"
        if derived is not None and derived[rate] != n_stream:
            print(f"BAD  {tag}: the instrument derives N_STREAM={derived[rate]} at this rate")
            bad += 1
            continue
        if declared is None:
            if frac < 0.999:
                print(f"BAD  {tag}: claimed line rate but the worst case is {frac:.3f} "
                      f"at {at_len} B")
                bad += 1
            else:
                print(f"OK   {tag}: line rate at every length from {LEN_MIN} to {LEN_MAX} B, "
                      f"transmit is line rate at and above {txl} B")
        else:
            if frac > declared + 0.02:
                print(f"BAD  {tag}: declared {declared:.2f} but measures {frac:.3f} at "
                      f"{at_len} B, so the declaration understates it and is stale")
                bad += 1
            elif frac < declared - 0.02:
                print(f"BAD  {tag}: declared {declared:.2f} but measures only {frac:.3f} at "
                      f"{at_len} B")
                bad += 1
            else:
                print(f"OK   {tag}: fallback, worst case {frac:.3f} at {at_len} B, "
                      f"transmit is line rate at and above {txl} B")

    for rate, n_stream, data_w, net_mhz, why in REFUSED:
        total += 1
        frac, at_len = worst_fraction(rate, n_stream, data_w, net_mhz)
        tag = f"RATE={rate} {n_stream}x{data_w} @ {net_mhz:.3f} MHz"
        if frac >= 0.999:
            print(f"BAD  {tag}: listed as refused but it reaches line rate, so the reason "
                  f"'{why}' is wrong")
            bad += 1
        elif derived is not None and derived[rate] == n_stream:
            print(f"BAD  {tag}: refused, worst case {frac:.3f} at {at_len} B, and the "
                  f"instrument derives exactly this stream count")
            bad += 1
        else:
            print(f"OK   {tag}: refused, worst case {frac:.3f} at {at_len} B, {why}")

    print(f"TOTAL {total} BAD {bad}")
    print("STREAM RATE RESULT: " + ("PASS" if bad == 0 else "FAIL"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
