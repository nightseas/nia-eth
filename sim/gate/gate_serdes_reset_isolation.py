#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_serdes_reset_isolation.py
# Description : Checks that a per client transceiver reset request reaches only its own
#               client, and proves the check is not vacuous against a mutated copy.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PHY = "dcmac_phy_wrapper.sv"

TOTAL = 0
BAD = 0

def chk(name, ok, saw, why=""):
    global TOTAL, BAD
    TOTAL += 1
    if ok:
        print("  OK   %s: %s" % (name, saw))
    else:
        BAD += 1
        print("  BAD  %s: %s" % (name, saw))
        if why:
            print("       %s" % why)

def read(path):
    with open(path, "r", errors="replace") as fh:
        return fh.read()

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text

def final_assign(body, vec):
    m = re.search(r"assign\s+%s\s*=\s*([^;]+);" % re.escape(vec), body)
    return m.group(1).strip() if m else None

def per_bit_block(body, name):
    for m in re.finditer(r"always_comb\s*begin\b", body):
        depth = 1
        i = m.end()
        for tok in re.finditer(r"\b(begin|end)\b", body[i:]):
            depth += 1 if tok.group(1) == "begin" else -1
            if depth == 0:
                block = body[i:i + tok.start()]
                if re.search(r"%s\s*\[" % re.escape(name), block):
                    return block
                break
    return None

def check(dcm):
    path = os.path.join(dcm, PHY)
    if not os.path.isfile(path):
        chk("C0 file", False, "%s not found" % path)
        return
    body = strip_comments(read(path))

    for vec, done in (("rx_serdes_reset", "rst_rx_done_q"),
                      ("tx_serdes_reset", "rst_tx_done_q")):
        rhs = final_assign(body, vec)
        if rhs is None:
            chk("C1 %s assigned" % vec, False, "no assign found")
            continue

        reps = re.findall(r"\{\s*6\s*\{([^}]*)\}\s*\}", rhs)
        offending = [r.strip() for r in reps if "core_serdes_reset" not in r]
        chk("C1 %s is not a broadcast of one term" % vec,
            not offending,
            "replications on the RHS: %s" % (reps if reps else "none"),
            "A replication of anything but core_serdes_reset applies one port's condition to all "
  "six, which is the defect of the plan. PG369 p111: bit N is port N.")

        chk("C1b %s keeps the PHY-wide core term" % vec,
            "core_serdes_reset" in rhs,
            "core_serdes_reset present" if "core_serdes_reset" in rhs else "MISSING",
            "PG369 p165 asserts the reset on all six ports at startup before releasing the active "
            "ones. That term is B4 and sys_reset and is deliberately PHY-wide.")

        inter = re.findall(r"([A-Za-z_]\w*)\s*\|", rhs) + re.findall(r"=\s*([A-Za-z_]\w*)\s*\|", rhs)
        name = "%s_i" % vec
        chk("C2 %s built per bit" % vec,
            name in rhs and re.search(r"%s\s*\[" % re.escape(name), body) is not None,
            "intermediate %s indexed per port" % name if name in rhs else "no per-bit intermediate",
            "The per-port form is what makes p166's 'does not affect other active ports' true.")

        block = per_bit_block(body, name)
        if block is None:
            chk("C3 %s isolation" % vec, False, "no always_comb block assigns %s" % name)
            continue
        assigns = re.findall(r"%s\s*\[\s*p\s*\]\s*=\s*([^;]+);" % re.escape(name), block)
        chk("C3a %s has per-port assignments" % vec,
            len(assigns) >= 2,
            "%d assignments to %s[p]" % (len(assigns), name),
            "Expect one per ownership branch plus the unowned branch.")
        if not assigns:
            chk("C3b %s isolation is not vacuous" % vec, False,
                "no assignments found, so the isolation checks cannot be evaluated",
                "A check that passes on an empty set proves nothing.")
            continue
        bad_terms = []
        for a in assigns:
            idxs = set(re.findall(r"%s\s*\[\s*([^\]]+?)\s*\]" % re.escape(done), a))
            if len(idxs) > 1:
                bad_terms.append((a.strip(), sorted(idxs)))
        reads_done = [a.strip() for a in assigns if re.search(r"%s\s*\[" % re.escape(done), a)]
        chk("C3b %s: each port bit reads ONE client's done bit" % vec,
            (not bad_terms) and len(reads_done) >= 1,
            "%d assignment(s) read %s, none mixes client indices" % (len(reads_done), done)
            if not bad_terms else str(bad_terms),
            "An assignment that reads more than one client's done bit couples two ports, which is "
            "exactly what the board measured as a traffic stall.")
        no_reduction = [a.strip() for a in assigns if re.search(r"&\s*%s\b" % re.escape(done), a)
                        or re.search(r"%s\s*[&|]" % re.escape(done), a)]
        chk("C3c %s: no reduction over the done vector in a port bit" % vec,
            not no_reduction,
            "no reduction in %d assignment(s)" % len(assigns) if not no_reduction
            else str(no_reduction),
            "A reduction such as ~(&rst_rx_done_q) makes every port depend on every quad.")

        held = re.search(r"%s\s*\[\s*p\s*\]\s*=\s*1'b1\s*;" % re.escape(name), block)
        chk("C4 %s holds an unowned port in reset" % vec,
            held is not None,
            "unowned branch drives 1'b1" if held else "MISSING",
            "PG369 p165 releases serdes_reset for ACTIVE ports only, so a port owned by no client "
            "stays asserted.")

    for pin, hold in (("rx_core_reset", "core_rst_rx_hold_r"),
                      ("tx_core_reset", "core_rst_tx_hold_r")):
        conns = re.findall(r"\.%s\s*\(\s*([^)]*?)\s*\)" % re.escape(pin), body)
        pin_alias = pin + "_pin"
        wrong = [c for c in conns if c != pin_alias]
        chk("C5a %s: every connection is the latched power-on hold" % pin,
            len(conns) >= 1 and not wrong,
            "%d connection(s), all %s" % (len(conns), pin_alias) if not wrong
            else "%d connection(s), wrong: %s" % (len(conns), wrong),
  ": domain 1 moves twice in the life of an image. A live term here resets the "
            "time-sliced MAC of EVERY port on any GT reset (PG369 p111, p166).")

        alias_ok = re.search(r"wire\s+%s\s*=\s*%s\s*;" % (re.escape(pin_alias), re.escape(hold)),
                             body)
        chk("C5b %s comes from a REGISTER, not an expression" % pin,
            alias_ok is not None,
            "driven by %s" % hold if alias_ok else "MISSING or not the hold register",
            "A latch is what makes 'released once' checkable. A combinational alias would let the "
            "condition become live again without any line looking wrong.")

    for hold in ("core_rst_rx_hold_r", "core_rst_tx_hold_r"):
        sets = re.findall(r"%s\s*<=\s*1'b1\s*;" % re.escape(hold), body)
        blk = re.search(r"if\s*\(\s*sys_reset_core_sync\s*\)\s*begin(.*?)end\s*else"
                        r"(.*?)\n\s*end\n", body, re.S)
        in_sysrst = blk is not None and ("%s <= 1'b1;" % hold) in blk.group(1)
        in_else = blk is not None and ("%s <= 1'b1;" % hold) in blk.group(2)
        chk("C5c %s re-asserts ONLY under sys_reset" % hold,
            len(sets) == 1 and in_sysrst and not in_else,
            "1 assignment, inside the sys_reset branch" if (len(sets) == 1 and in_sysrst
                                                            and not in_else)
            else "%d assignment(s), sys_reset_branch=%s else_branch=%s"
                 % (len(sets), in_sysrst, in_else),
  "/: a reset with a path back to asserted from any live status is the defect "
            "in a different shape.")

        clr = re.search(r"if\s*\(\s*clk_wiz_locked\s*&&\s*!gt_%s_notdone_core_sync\s*\)\s*"
                        r"%s\s*<=\s*1'b0\s*;" % (hold.split("_")[2], re.escape(hold)), body)
        chk("C5d %s releases on locked AND all-quads-done" % hold,
            clr is not None,
            "clear condition present" if clr else "MISSING or changed",
            "PG369 p110: the pins are held until the relevant clocks are stable. This is the ONE "
            "place the cross-quad AND is correct.")

    for term, src, sync in (("gt_rx_all_done", "rst_rx_done_q", "gt_rx_notdone_core_sync"),
                            ("gt_tx_all_done", "rst_tx_done_q", "gt_tx_notdone_core_sync")):
        m = re.search(r"wire\s+%s\s*=\s*&\s*%s\s*;" % (re.escape(term), re.escape(src)), body)
        chk("C6a %s is the cross-quad AND" % term,
            m is not None,
            "present" if m else "MISSING or changed",
  "It is correct as the first-release gate.  bounds where it may appear, not whether.")

        uses = [ln.strip() for ln in body.splitlines()
                if re.search(r"\b%s\b" % re.escape(term), ln)
                and not re.search(r"wire\s+%s\s*=" % re.escape(term), ln)]
        ok = len(uses) == 1 and ".reset_async(~%s)" % term in uses[0].replace(" ", "")
        chk("C6b %s is used ONLY by the hold's synchroniser" % term,
            ok,
            "1 use, the syncer" if ok else "%d use(s): %s" % (len(uses), uses),
  ": a cross-quad term on any other net is a per-port action with MAC-wide reach.")

    seg_port = re.search(r"output\s+wire\s*\[\s*N_CLIENT\s*-\s*1\s*:\s*0\s*\]\s*seg_rstn\s*,", body)
    chk("C7 seg_rstn is a per-client vector",
        seg_port is not None,
        "output [N_CLIENT-1:0] seg_rstn" if seg_port else "MISSING or still scalar",
  ". A scalar cannot express per-port scope, so the property would be unreachable no "
        "matter what drives it.")

    seg_asgs = re.findall(r"assign\s+seg_rstn\s*\[\s*([A-Za-z_]\w*)\s*\]\s*=\s*([^;]+);", body)
    chk("C8a seg_rstn is assigned per index, in a loop",
        len(seg_asgs) >= 1,
        "%d indexed assignment(s): %s" % (len(seg_asgs), [i for i, _ in seg_asgs])
        if seg_asgs else "no indexed assignment",
        "A single `assign seg_rstn = {N{x}}` in the real PHY would be the old shared reset wearing "
        "a vector's clothes.")

    for idx, expr in seg_asgs:
        flat = expr.replace(" ", "").replace("\n", "")
        reduction = re.search(r"[&|]\s*rst_[rt]x_done_q\b", expr) or "(&rst_" in flat
        other = re.findall(r"rst_[rt]x_done_q\s*\[\s*([^\]]+?)\s*\]", expr)
        bad_idx = [o for o in other if o != idx]
        chk("C8b seg_rstn[%s] reads its own quad only" % idx,
            not reduction and not bad_idx,
            "own index only" if (not reduction and not bad_idx)
            else "reduction=%s foreign_index=%s" % (bool(reduction), bad_idx),
  "/: this is the defect that defeated the per-client terms above it.")

    str_rst = re.findall(r"if\s*\(\s*!\s*(seg_rstn\s*\[\s*c\s*\]|rstn_tx_axi|rstn_rx_axi)\s*\)",
                         body)
    ok9 = bool(str_rst) and all("seg_rstn" in x for x in str_rst)
    chk("C9 the RX-DP stretcher is reset per client",
        ok9,
        "resets from %s" % sorted(set(x.replace(" ", "") for x in str_rst)) if str_rst
        else "no stretcher reset found",
  ": client c's stretcher held by a cross-quad term is a recovery pulse one cage can "
        "truncate on the other.")

MUTANTS = [
    ("M1_restore_the_broadcast",
     "assign rx_serdes_reset = rx_serdes_reset_i | {6{core_serdes_reset}};",
     "assign rx_serdes_reset = {6{gt_rx_reset_done_inv | core_serdes_reset}};",
     "the exact defect measured on a board: one scalar from a cross-quad AND, broadcast to six"),
    ("M2_restore_the_broadcast_tx",
     "assign tx_serdes_reset = tx_serdes_reset_i | {6{core_serdes_reset}};",
     "assign tx_serdes_reset = {6{gt_tx_reset_done_inv | core_serdes_reset}};",
     "the same defect on the transmit path, which was reachable from a host request"),
    ("M3_port_reads_both_clients",
     "        rx_serdes_reset_i[p] = ~rst_rx_done_q[0];",
     "        rx_serdes_reset_i[p] = ~rst_rx_done_q[0] | ~rst_rx_done_q[(N_CLIENT > 1) ? 1 : 0];",
     "a port bit that reads the sibling's done bit as well as its own"),
    ("M4_reduction_in_a_port_bit",
     "        rx_serdes_reset_i[p] = ~rst_rx_done_q[0];",
     "        rx_serdes_reset_i[p] = ~(&rst_rx_done_q);",
     "a reduction over the whole done vector inside one port's bit"),
    ("M5_unowned_port_released",
     "        rx_serdes_reset_i[p] = 1'b1;",
     "        rx_serdes_reset_i[p] = 1'b0;",
     "an inactive port released from reset, against PG369 p165"),
    ("M6_core_reset_made_live_again",
     ".rx_core_reset(rx_core_reset_pin)",
     ".rx_core_reset(gt_rx_notdone_core_sync)",
     "THE MEASURED DEFECT, restored: a live cross-quad term on the MAC core reset, so a GT reset on "
     "one quad resets the time-sliced MAC of every port (PG369 p111, p166)"),
    ("M7_all_done_weakened",
     "wire gt_rx_all_done = &rst_rx_done_q;",
     "wire gt_rx_all_done = |rst_rx_done_q;",
     "the first-release gate weakened from every quad to any quad, against PG369 p110"),
    ("M8_hold_can_reassert",
     "      if (clk_wiz_locked && !gt_rx_notdone_core_sync) core_rst_rx_hold_r <= 1'b0;",
     "      if (clk_wiz_locked && !gt_rx_notdone_core_sync) core_rst_rx_hold_r <= 1'b0;\n"
     "      else core_rst_rx_hold_r <= 1'b1;",
     "a path back to asserted from live status: the same defect wearing a register's clothes"),
    ("M9_all_done_leaks_to_a_pin",
     "  wire rx_core_reset_pin = core_rst_rx_hold_r;",
     "  wire rx_core_reset_pin = core_rst_rx_hold_r | ~gt_rx_all_done;",
  "the cross-quad term reaching a pin again, this time as an extra OR term "),
    ("M10_seg_rstn_shared_again",
     "    assign seg_rstn[qs] = clk_wiz_locked & ~notdone_rx_axis & ~notdone_tx_axis;",
     "    assign seg_rstn[qs] = clk_wiz_locked & ~(&rst_rx_done_q) & ~(&rst_tx_done_q);",
     "the shared segmented reset restored inside a per-client loop: a vector that is not per client"),
    ("M11_seg_rstn_reads_both_quads",
     "    assign seg_rstn[qs] = clk_wiz_locked & ~notdone_rx_axis & ~notdone_tx_axis;",
     "    assign seg_rstn[qs] = clk_wiz_locked & ~notdone_rx_axis & ~notdone_tx_axis"
     " & rst_rx_done_q[(N_CLIENT > 1) ? 1 : 0];",
     "one client's segmented reset made to depend on the sibling's quad"),
    ("M12_stretcher_held_cross_quad",
     "      if (!seg_rstn[c]) begin",
     "      if (!(&seg_rstn)) begin",
     "client c's recovery pulse truncated by the other cage's reset-done"),
]

def selftest(dcm):
    src = os.path.join(dcm, PHY)
    base = read(src)
    caught = 0
    print("SELFTEST: %d mutants, each applied to a COPY" % len(MUTANTS))
    for name, old, new, why in MUTANTS:
        if old not in base:
            print("  ANCHOR MISSING %s: %r" % (name, old[:70]))
            continue
        tmp = tempfile.mkdtemp(prefix="gate_iso_")
        try:
            shutil.copytree(dcm, os.path.join(tmp, "dcmac"), symlinks=True,
                            ignore=shutil.ignore_patterns("sim*", "__pycache__", "ip", "build*"))
            dst = os.path.join(tmp, "dcmac", PHY)
            with open(dst, "w") as fh:
                fh.write(base.replace(old, new, 1))
            rc = subprocess.call([sys.executable, os.path.abspath(__file__),
                                  "--dcm", os.path.join(tmp, "dcmac")],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if rc != 0:
                caught += 1
                print("  CAUGHT   %-28s exit=%d  (%s)" % (name, rc, why))
            else:
                print("  SURVIVED %-28s exit=0   (%s)" % (name, why))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST TOTAL %d BAD %d" % (len(MUTANTS), len(MUTANTS) - caught))
    return 0 if caught == len(MUTANTS) else 99

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dcm", default=os.path.dirname(HERE) if os.path.basename(HERE) == "sim"
                    else HERE)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    dcm = os.path.abspath(a.dcm)
    if a.selftest:
        return selftest(dcm)
    print("NIA_GATE_SERDES_RESET_ISOLATION  dcm=%s" % dcm)
    check(dcm)
    print("TOTAL %d BAD %d" % (TOTAL, BAD))
    print("SERDES-RESET ISOLATION: %s" % ("PASS" if BAD == 0 else "FAIL"))
    return BAD

if __name__ == "__main__":
    sys.exit(main())
