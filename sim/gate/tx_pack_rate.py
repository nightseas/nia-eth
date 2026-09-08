#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : tx_pack_rate.py
# Description : The transmit rate arithmetic of the segment packing converter. It states,
#               for each rate and each frame length, the fraction of line rate the
#               transmit side can reach before and after packing, and which of the three
#               caps binds. The caps are the segment cap N_SEG segments per segmented
#               cycle, the input beat cap one DATA_W beat per segmented cycle, and the
#               host stream cap one DATA_W beat per net clock.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import math
import sys

SLOT_OVERHEAD = 24         # frame check sequence, preamble and interpacket gap
SEG_MHZ = 390.930          # the DCMAC segmented interface clock this repository constrains
SEG_W = 128

# RATE -> N_SEG, DATA_W, the net clocks the flow may build
GEOM = {
    100: (2,  512, (390.625, 250.000)),
    200: (4, 1024, (390.625, 250.000)),
    400: (8, 1024, (390.625, 250.000)),
}

LENGTHS = (64, 65, 96, 97, 128, 129, 257, 385, 1518)


def demand(rate_gbps, length):
    """Frames per second the wire imposes at this length."""
    return rate_gbps * 1e9 / 8.0 / (length + SLOT_OVERHEAD)


def caps_after(rate_gbps, n_seg, data_w, net_mhz, length):
    """The three caps in frames per second after packing, and their names."""
    seg_b = SEG_W // 8
    beat_b = data_w // 8
    segment_cap = n_seg * SEG_MHZ * 1e6 / math.ceil(length / seg_b)
    beat_cap = SEG_MHZ * 1e6 / math.ceil(length / beat_b)
    host_cap = net_mhz * 1e6 / math.ceil(length / beat_b)
    return (("segment", segment_cap), ("input beat", beat_cap), ("host stream", host_cap))


def cap_before(rate_gbps, n_seg, data_w, net_mhz, length):
    """One start of packet per segmented cycle, over a stream cut to N_SEG*SEG_W first.
    A frame occupies ceil(length / (N_SEG*SEG_W/8)) segmented cycles."""
    seg_bits_b = n_seg * SEG_W // 8
    beat_b = data_w // 8
    sop_cap = SEG_MHZ * 1e6 / math.ceil(length / seg_bits_b)
    host_cap = net_mhz * 1e6 / math.ceil(length / beat_b)
    return min(sop_cap, host_cap)


def block_cap(n_seg, data_w, length, block_beats):
    """Frames per second the block mechanism presents. A block closes at the first end of
    frame at or after block_beats beats, and the group that holds that end of frame is padded
    to a whole group. The cost is therefore up to n_seg-1 wasted segments per block."""
    seg_b = SEG_W // 8
    beat_b = data_w // 8
    beats_per_frame = math.ceil(length / beat_b)
    segs_per_frame = math.ceil(length / seg_b)
    frames = max(1, math.ceil(block_beats / beats_per_frame))
    segs = frames * segs_per_frame
    groups = math.ceil(segs / n_seg)
    return frames * SEG_MHZ * 1e6 / groups


def worst_over_all_lengths(rate_gbps, n_seg, data_w, net_mhz, block_beats):
    worst, at_len, why = None, None, None
    for length in range(64, 9019):
        d = demand(rate_gbps, length)
        caps = list(caps_after(rate_gbps, n_seg, data_w, net_mhz, length))
        caps.append(("block pad", block_cap(n_seg, data_w, length, block_beats)))
        name, value = min(caps, key=lambda kv: kv[1])
        f = min(value / d, 1.0)
        if worst is None or f < worst:
            worst, at_len, why = f, length, name
    return worst, at_len, why


def main():
    for block_beats in (8, 16, 32, 64, 128, 256, 512):
        line = f"BLOCK_BEATS={block_beats:>4}"
        for rate in (100, 200, 400):
            n_seg, data_w, _ = GEOM[rate]
            w, at_len, why = worst_over_all_lengths(rate, n_seg, data_w, 390.625, block_beats)
            line += f"   {rate}G {w:.4f} at {at_len}B ({why})"
        print(line)
    print()
    print(f"SEG_MHZ={SEG_MHZ} SEG_W={SEG_W} SLOT_OVERHEAD={SLOT_OVERHEAD}")
    for rate in (100, 200, 400):
        n_seg, data_w, net_clocks = GEOM[rate]
        for net_mhz in net_clocks:
            print(f"\nRATE={rate} N_SEG={n_seg} DATA_W={data_w} NET_MHZ={net_mhz:.3f}")
            print(f"  {'len':>5} {'demand Mfps':>12} {'before':>8} {'after':>8}  binding cap after")
            for length in LENGTHS:
                d = demand(rate, length)
                b = cap_before(rate, n_seg, data_w, net_mhz, length)
                caps = caps_after(rate, n_seg, data_w, net_mhz, length)
                name, value = min(caps, key=lambda kv: kv[1])
                print(f"  {length:>5} {d/1e6:>12.2f} {min(b/d,1.0):>8.3f} "
                      f"{min(value/d,1.0):>8.3f}  {name} at {value/1e6:.2f} Mfps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
