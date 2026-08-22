#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : golden_dual.py
# Description : The golden write trace for two groups, including which writes are per port
#               and must appear once per slot.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REF = os.environ.get("COYOTE_CTL_SIM", _HERE)
if _REF not in sys.path:
    sys.path.insert(0, _REF)

import golden as G

ORDER = os.environ.get("NS20_ORDER", "phase_major")

T_STEP2_SETTLE_MS = 5
T_PORT_CHAN_GAP_MS = 50

def group_ports(anchors, nports):
    ports = []
    for a, n in zip(anchors, nports):
        ports.extend(range(a, a + n))
    dupes = [p for p in ports if ports.count(p) > 1]
    assert not dupes, (
        f"the client groups OVERLAP on MAC port(s) {sorted(set(dupes))}: anchors={anchors} "
  f"nports={nports}. Two clients cannot share a MAC slot, so this is a bad variant, "
        f"not a bad ROM.")
    if list(anchors) != sorted(anchors):
        print(f"NOTE golden_dual: anchors {anchors} are not ascending, so the ROM's group-major "
              f"walk {ports} differs from slot order {sorted(ports)}. The golden follows the ROM.")
    return ports

def config_phase_dual(anchors=(0, 1), nports=(1, 1), rate=0, field=0x04, base=0,
                      nonanchor_field=0x04, with_waits=False, order=None):
    order = order or ORDER
    assert order in ("phase_major", "group_major"), order
    g = lambda off: base + off
    P = lambda p, off: G.pp(p, off, base)
    ports = group_ports(anchors, nports)
    anchors = tuple(anchors)
    t = []

    if order == "group_major":
        for a, n in zip(anchors, nports):
            t += G.config_phase(nports=n, anchor=a, rate=rate, field=field, base=base,
                                nonanchor_field=nonanchor_field)
        return t

    t.append(("W", g(G.O_PCTL_RX), 0x7))
    t.append(("W", g(G.O_PCTL_TX), 0x7))
    for p in range(G.PORT_MAX):
        t.append(("W", P(p, G.O_PCTL_RX), 0x3))
        t.append(("W", P(p, G.O_PCTL_TX), 0x3))
    for p in ports:
        t.append(("W", P(p, G.O_CHCTL_RX), 0x1))
        t.append(("W", P(p, G.O_CHCTL_TX), 0x1))
        if with_waits:
            t.append(("WAIT", T_STEP2_SETTLE_MS))
        t.append(("W", P(p, G.O_PCTL_RX), 0x3))
        t.append(("W", P(p, G.O_PCTL_TX), 0x3))

    t.append(("W", g(G.O_GLOBAL_MODE), G.W_GLOBAL_MODE))

    for i in range(G.PORT_MAX):
        t.append(("W", P(i, G.O_GLOBAL_MODE), G.W_PORT_MODE))
    for i in range(G.PORT_MAX):
        t.append(("W", P(i, G.O_CONFIG_REV), G.W_PORT_REV))

    for p in range(G.PORT_MAX):
        r = rate if p in anchors else 0
        f = field if p in anchors else nonanchor_field
        wtx, wrx = G._mode_words(r, f)
        t.append(("W", P(p, G.O_TX_MODE), wtx))
        t.append(("W", P(p, G.O_RX_MODE), wrx))

    t.append(("W", g(G.O_PCTL_TX), 0x0))
    t.append(("W", g(G.O_PCTL_RX), 0x0))
    for p in range(G.PORT_MAX):
        t.append(("W", P(p, G.O_PCTL_TX), 0x0))
        t.append(("W", P(p, G.O_PCTL_RX), 0x0))
    for p in ports:
        t.append(("W", P(p, G.O_PCTL_RX), 0x0))
        t.append(("W", P(p, G.O_PCTL_TX), 0x0))

    if with_waits:
        t.append(("WAIT", T_PORT_CHAN_GAP_MS))
    for p in ports:
        t.append(("W", P(p, G.O_CHCTL_TX), 0x0))
        t.append(("W", P(p, G.O_CHCTL_RX), 0x0))
    return t

def writes_only(trace):
    return [x for x in trace if x[0] in ("W", "R")]

def wait_points(trace):
    out = []
    n_w = 0
    for item in trace:
        if item[0] == "WAIT":
            out.append((n_w - 1, item[1]))
        else:
            n_w += 1
    return out

def group_realign_dual(anchors, nports, base=0):
    return [G.group_realign(nports=n, anchor=a, base=base) for a, n in zip(anchors, nports)]

def pmtick_dual(anchors, nports, base=0):
    t = []
    for p in group_ports(anchors, nports):
        t.append(("W", G.pp(p, G.O_TICK_RX, base), 0x1))
        t.append(("W", G.pp(p, G.O_TICK_TX, base), 0x1))
    return t

def equivalence_check(verbose=True):
    shapes = [(1, 0), (1, 1), (1, 2), (2, 0), (4, 0), (2, 2)]
    bad = 0
    for nports, anchor in shapes:
        if anchor + nports > G.PORT_MAX:
            continue
        for rate, field in ((0, 0x04), (1, 0x02)):
            ref = G.config_phase(nports=nports, anchor=anchor, rate=rate, field=field)
            mine = config_phase_dual(anchors=(anchor,), nports=(nports,), rate=rate, field=field)
            tag = f"nports={nports} anchor={anchor} rate={rate} field={field:#04x}"
            if ref == mine:
                if verbose:
                    print(f"OK   reduction {tag}: {len(ref)} writes identical to the reference")
            else:
                bad += 1
                print(f"BAD  reduction {tag}: {len(mine)} vs {len(ref)} writes")
                for i, (a, b) in enumerate(zip(mine, ref)):
                    if a != b:
                        print(f"     first divergence at {i}: mine={a} ref={b}")
                        break
    for anchors, nports in (((0, 1), (1, 1)), ((0, 2), (1, 1)), ((0, 2), (2, 2))):
        d = config_phase_dual(anchors=anchors, nports=nports)
        s = G.config_phase(nports=nports[0], anchor=anchors[0])
        tag = f"anchors={anchors} nports={nports}"
        extra_ports = len(group_ports(anchors, nports)) - nports[0]
        want = len(s) + 8 * extra_ports
        if len(d) == want:
            print(f"OK   dual {tag}: {len(d)} writes = {len(s)} + 8 x {extra_ports} extra port(s)")
        else:
            bad += 1
            print(f"BAD  dual {tag}: {len(d)} writes, expected {want}")
        for p in group_ports(anchors, nports):
            for off in (G.O_CHCTL_RX, G.O_CHCTL_TX, G.O_PCTL_RX, G.O_PCTL_TX,
                        G.O_TX_MODE, G.O_RX_MODE):
                if not any(a == G.pp(p, off) for _, a, _ in d):
                    bad += 1
                    print(f"BAD  dual {tag}: no write to port {p} offset {off:#05x}")
        for a in anchors:
            wtx, _ = G._mode_words(0, 0x04)
            if ("W", G.pp(a, G.O_TX_MODE), wtx) not in d:
                bad += 1
                print(f"BAD  dual {tag}: anchor {a} did not get the TX rate word {wtx:#010x}")
    n = len(shapes) * 2 + 3
    print(f"TOTAL {n} BAD {bad}")
    return bad

if __name__ == "__main__":
    print(f"REFERENCE golden.py from: {_REF}")
    print(f"ORDER = {ORDER}")
    sys.exit(1 if equivalence_check() else 0)
