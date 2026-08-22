#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_quad_readiness.py
# Description : Checks the transceiver quad readiness wiring in every instantiation,
#               against a fixture that is known good.
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
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))

MIN_STAGES = 2
SYNC_MODULE = "dcmac_sync2"
DEFAULT_FILE = os.path.join(RTL, "dcmac_mac_group.sv")
DEFAULT_SYNC_SRC = os.path.join(RTL, SYNC_MODULE + ".sv")

DIRS = {
    "tx": dict(raw="gt_tx_reset_done_raw", syn="gt_tx_done_sync", ready="gt_tx_done_all"),
    "rx": dict(raw="gt_rx_reset_done_raw", syn="gt_rx_done_sync", ready="gt_rx_done_all"),
}
DOWNSTREAM = {"dcmac_port": os.path.join(RTL, "dcmac_port.sv")}
DRIVER_MODULE = "dcmac_phy"
def _port_name(d):
    return "gt_%s_reset_done" % d

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(ln.split("//")[0] for ln in text.splitlines())

def balanced(text, open_idx):
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i + 1
    return "", len(text)

def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out

def named_assoc(s):
    out = {}
    for item in split_top(s):
        m = re.match(r"\s*\.\s*([A-Za-z_]\w*)\s*\(", item)
        if not m:
            continue
        inner, _ = balanced(item, item.index("(", m.end(1)))
        out[m.group(1)] = " ".join(inner.split())
    return out

def find_instances(code, module):
    out = []
    for m in re.finditer(r"\b" + re.escape(module) + r"\b\s*(#\s*\()?", code):
        pos = m.end()
        params = {}
        if m.group(1):
            inner, pos = balanced(code, m.end() - 1)
            params = named_assoc(inner)
        mi = re.match(r"\s*([A-Za-z_]\w*)\s*\(", code[pos:])
        if not mi:
            continue
        cpos = pos + mi.end() - 1
        inner, _ = balanced(code, cpos)
        out.append(dict(inst=mi.group(1), params=params, conns=named_assoc(inner),
                        at=code[:m.start()].count("\n") + 1))
    return out

def enclosing_for(code, upto_line, quads):
    best = (None, None)
    for m in re.finditer(r"\bfor\s*\(\s*(?:genvar\s+|int\s+|integer\s+)?"
                         r"([A-Za-z_]\w*)\s*=\s*0\s*;\s*\1\s*<\s*([^;]+?)\s*;", code):
        line = code[:m.start()].count("\n") + 1
        if line <= upto_line:
            best = (m.group(1), m.group(2).strip())
    return best

def covers_all_quads(bound, quads):
    b = bound.strip()
    if b in ("N_CLIENT", "NUM_QUADS", "N_QUAD", "QUADS"):
        return True
    return b.isdigit() and int(b) >= quads

def check(path=None, quads=2, sync_src=None, verbose=True):
    path = path or DEFAULT_FILE
    sync_src = sync_src or DEFAULT_SYNC_SRC
    n_total = n_bad = 0

    def ok(msg):
        nonlocal n_total
        n_total += 1
        if verbose:
            print("OK   " + msg)

    def bad(msg):
        nonlocal n_total, n_bad
        n_total += 1
        n_bad += 1
        print("BAD  " + msg)

    if not os.path.exists(path):
        print("BAD  file not found: %s" % path)
        print("TOTAL 1 BAD 1")
        return 1
    code = strip_comments(open(path).read())

    if not os.path.exists(sync_src):
        bad("synchroniser module source not found: %s.  NOT VACUOUSLY OK - the `ASYNC_REG` "
            "attribute of this idiom lives INSIDE that file (this was half of audit ), so "
            "without it nothing about 's CDC property is checked" % sync_src)
    else:
        s = strip_comments(open(sync_src).read())
        m_attr = re.search(r"\(\*[^*]*ASYNC_REG[^*]*\*\)\s*reg\b[^;]*;", s)
        if m_attr:
            ok("`%s` carries ASYNC_REG on its shift register: %s"
               % (SYNC_MODULE, " ".join(m_attr.group(0).split())))
        else:
            bad("`%s` has NO `(* ASYNC_REG *)` attribute on a reg declaration.: "
                "`get_property ASYNC_REG` is not a witness and `report_cdc`'s 'No ASYNC_REG' "
                "column is - this gate is the pre-build half of that check, so a missing "
                "attribute must not reach a build to be discovered" % SYNC_MODULE)
        if re.search(r"STAGES\s*<\s*2[^;]*?\$fatal|\$fatal[^;]*STAGES", s, re.S):
            ok("`%s` $fatal()s at elaboration on STAGES < 2 (a 1-stage 'synchroniser' cannot "
               "be instantiated by accident)" % SYNC_MODULE)
        else:
            bad("`%s` does not $fatal on STAGES < 2 - the floor is unenforced" % SYNC_MODULE)
        if re.search(r"sr\s*\[\s*0\s*\]\s*<=\s*din\s*;", s):
            ok("`%s` stage 0 captures `din` directly - no logic inside the crossing "
               "(putting a reduction inside is  in a different costume)" % SYNC_MODULE)
        else:
            bad("`%s`: stage 0 does not capture `din` directly. Logic inside the crossing is "
                "the  mistake" % SYNC_MODULE)

    insts = find_instances(code, SYNC_MODULE)
    if not insts:
        bad("no `%s` instance in %s.  NOT VACUOUSLY OK: 's corrected test column names "
            "this idiom explicitly (an instance over a vector slice, the attribute inside that "
            "module). Either the synchronisers are gone, or this gate is aimed at the wrong file."
            % (SYNC_MODULE, os.path.basename(path)))
        print("FILE  %s" % path)
        print("TOTAL %d BAD %d" % (n_total, n_bad))
        return 1

    for d, nm in sorted(DIRS.items()):
        raw, syn, ready = nm["raw"], nm["syn"], nm["ready"]
        mine = [i for i in insts if raw in i["conns"].get("din", "")]

        if not mine:
            bad("%s: no `%s` instance captures `%s`.  The raw per-quad word crosses "
                "free-run -> tx_clk unsynchronised - 's exact shape, which was 213 of 213 "
                "failing setup endpoints" % (d, SYNC_MODULE, raw))
            continue
        for i in mine:
            st = i["params"].get("STAGES", "?")
            try:
                nst = int(st)
            except ValueError:
                nst = -1
            if nst >= MIN_STAGES:
                ok("%s `%s`: STAGES=%d (>= %d)" % (d, i["inst"], nst, MIN_STAGES))
            else:
                bad("%s `%s`: STAGES=%s, need >= %d.  was 213 of 213 failing "
                    "endpoints from exactly this, and NO SIMULATION CAN SEE IT - an ideal clock "
                    "model captures a single flop happily" % (d, i["inst"], st, MIN_STAGES))
        if len(mine) >= quads:
            ok("%s: %d literal instances for %d quad(s) - replicated, not shared"
               % (d, len(mine), quads))
        else:
            var, bound = enclosing_for(code, mine[0]["at"], quads)
            if var and covers_all_quads(bound, quads):
                if re.search(r"\b" + re.escape(var) + r"\b", mine[0]["conns"].get("din", "")):
                    ok("%s: 1 instance inside `for (%s = 0; %s < %s ...)` and `.din` is indexed "
                       "by `%s` => %d chains elaborate, one per quad ('replicated, not "
                       "shared')" % (d, var, var, bound, var, quads))
                else:
                    bad("%s: the instance is inside `for (%s < %s ...)` but its `.din` (`%s`) is "
                        "NOT indexed by `%s` - every quad's chain would capture the same bits, "
                        "which is one shared synchroniser wearing a generate loop"
                        % (d, var, bound, mine[0]["conns"].get("din", ""), var))
            else:
                bad("%s: %d instance(s) for %d quads and no enclosing loop covering all of "
                    "them (innermost bound = %r).  requires the synchroniser REPLICATED PER "
                    "QUAD" % (d, len(mine), quads, bound))

        for i in mine:
            din, dout = i["conns"].get("din", ""), i["conns"].get("dout", "")
            di = re.search(r"\[(.+)\]", din)
            do = re.search(r"\[(.+)\]", dout)
            if not di or not do:
                bad("%s `%s`: `.din`/`.dout` are not sliced (`%s` -> `%s`), so per-quad "
                    "derivation cannot be established" % (d, i["inst"], din, dout))
            elif " ".join(di.group(1).split()) == " ".join(do.group(1).split()):
                ok("%s `%s`: `.din`/`.dout` share the index expression `[%s]` => quad q's "
                   "synchronised word carries quad q's raw word" % (d, i["inst"], di.group(1)))
            else:
                bad("%s `%s`: `.din` is indexed `[%s]` but `.dout[%s]`.: the "
                    "synchroniser is REPLICATED PER QUAD, NOT SHARED - two quads are two "
                    "asynchronous sources and one chain cannot serve both. This is name-only "
                    "compliance: the chain LOOKS per-quad and carries another quad's data"
                    % (d, i["inst"], di.group(1), do.group(1)))
            if syn not in dout:
                bad("%s `%s`: `.dout` (`%s`) does not drive `%s`, so the readiness reduction "
                    "cannot be reading this crossing" % (d, i["inst"], dout, syn))
            else:
                ok("%s `%s`: `.dout` drives `%s`" % (d, i["inst"], syn))

        seed = re.search(r"\b" + re.escape(ready) + r"\s*=\s*([^;]+);", code)
        base = seed.end() if seed else 0
        red = re.search(r"\b" + re.escape(ready) + r"\s*(&=|\|=|=)\s*([^;]+);", code[base:])
        if not seed:
            bad("%s: no assignment to `%s` found.  NOT VACUOUSLY OK - 's comparator "
                "could not be located, which is exactly how  read as a pass" % (d, ready))
        else:
            sv = seed.group(1).strip()
            if re.fullmatch(r"(\d+'[hH][fF]+|'1|\{?\s*\d+\s*\{\s*1'b1\s*\}\s*\}?|~'0)", sv):
                ok("%s `%s` seeded ALL-ONES (%s) - the identity of AND, so the reduction can "
                   "only ever remove readiness" % (d, ready, sv))
            else:
                bad("%s `%s` seeded `%s`, not all-ones. An AND reduction seeded with anything "
                    "else either forces readiness or is not an AND" % (d, ready, sv))
        if not red:
            bad("%s: no reduction into `%s` found after its seed.: the readiness shall "
                "AND BOTH quads' synchronised words" % (d, ready))
        else:
            op, rhs = red.group(1), " ".join(red.group(2).split())
            if op == "&=":
                ok("%s `%s %s %s` - a bitwise AND, so readiness requires EVERY quad"
                   % (d, ready, op, rhs))
            else:
                bad("%s `%s %s %s` - NOT an AND. `|=` declares the GT ready on ONE quad while "
                    "the other is still in reset; on the wire that is a link that SOMETIMES "
                    "comes up, the intermittency shape that has cost this program two hardware "
                    "campaigns (6/10 -> 15/15;  7/10 -> 20/20)" % (d, ready, op, rhs))
            if syn in rhs:
                ok("%s reduction reads the SYNCHRONISED word `%s`" % (d, syn))
            else:
                bad("%s reduction reads `%s`, not the synchronised word `%s`.  If it reads "
                    "the raw word the crossing is bypassed entirely - 's literal shape"
                    % (d, rhs, syn))
            var, bound = enclosing_for(code, code[:base + red.start()].count("\n") + 1, quads)
            if var and covers_all_quads(bound, quads):
                ok("%s reduction loops `%s = 0 .. %s` => every quad is ANDed in"
                   % (d, var, bound))
            elif var:
                bad("%s reduction loops `%s < %s`, which does NOT cover %d quads.  THE "
                    "MUTANT  NAMES: quad 1 dropped from the readiness AND releases the "
                    "sequencer while the SECOND cage is still in reset"
                    % (d, var, bound, quads))
            else:
                bad("%s reduction is not inside a loop over the quads and there are not %d "
                    "literal terms - the 'both quads' property is unestablished"
                    % (d, quads))
            if DIRS["rx" if d == "tx" else "tx"]["syn"] in rhs:
                bad("%s readiness mixes the OTHER direction's synchronised word (`%s`). RX and "
                    "TX must stay separate: the vendor exdes defect this program root-caused was "
                    "exactly one shared bit "
                    % (d, DIRS["rx" if d == "tx" else "tx"]["syn"]))
            else:
                ok("%s readiness references only its own direction" % d)

        offenders = []
        for m in re.finditer(r"\b" + re.escape(raw) + r"\b", code):
            line = code[:m.start()].count("\n") + 1
            before = code[max(0, m.start() - 400):m.start()]
            decl = re.search(r"(wire|logic|reg)[^;]*$", before)
            if decl and ";" not in before[decl.start():]:
                continue
            pm = re.search(r"\.\s*([A-Za-z_]\w*)\s*\(\s*$", before)
            if pm:
                port = pm.group(1)
                if port == "din":
                    continue
                if port == _port_name(d):

                    whole = code[:m.start()]
                    mod, best = None, -1
                    for cand in list(DOWNSTREAM) + [DRIVER_MODULE]:
                        k = whole.rfind(cand)
                        if k > best:
                            mod, best = cand, k
                    if mod == DRIVER_MODULE:
                        continue
                    if mod in DOWNSTREAM:
                        continue
                offenders.append((line, port))
            else:
                offenders.append((line, "<bare expression>"))
        if offenders:
            bad("%s `%s`: %d load(s) that are NOT a stage-0 synchroniser input: %s.  A raw "
                "asynchronous per-quad word used anywhere else is /'s literal shape - "
                "the mistake made TWICE IN THE SAME FILE, both times behind the sentence 'no "
                "combinational path crosses a domain boundary anywhere' "
                % (d, raw, len(offenders),
                   ", ".join("line %d in `.%s`" % (l, p) for l, p in offenders)))
        else:
            ok("%s `%s`: every load is a stage-0 `ASYNC_REG` synchroniser input (its own "
               "`.din`, or a downstream port earned by )" % (d, raw))

    for mod, src in sorted(DOWNSTREAM.items()):
        if not os.path.exists(src):
            bad("`%s` source not found (%s) - its whitelist entry in is then an "
                "ASSERTION, and  exists because assertions about crossings were wrong "
                "twice" % (mod, src))
            continue
        dcode = strip_comments(open(src).read())
        dinsts = find_instances(dcode, SYNC_MODULE)
        for d in sorted(DIRS):
            port = _port_name(d)
            if not re.search(r"\b" + re.escape(port) + r"\b", dcode):
                continue
            syncd = any(re.search(r"\b" + re.escape(port) + r"\b", i["conns"].get("din", ""))
                        for i in dinsts)

            uses = len([m for m in re.finditer(r"\b" + re.escape(port) + r"\b", dcode)
                        if not dcode[:m.start()].rstrip().endswith(".")])
            if syncd and uses <= 2:
                ok("`%s`.%s feeds a `%s` `.din` and is used %d time(s) (declaration + that "
                   "`.din`) => C3's whitelist entry is EARNED, not asserted"
                   % (mod, port, SYNC_MODULE, uses))
            elif syncd:
                bad("`%s`.%s feeds a `%s` `.din` but has %d textual uses (> 2) - it is ALSO "
                    "used somewhere else, so handing it the raw word is not safe"
                    % (mod, port, SYNC_MODULE, uses))
            else:
                bad("`%s`.%s does NOT feed a `%s` `.din`. => must stop allowing the raw "
                    "word to be handed to `%s`: that is an unsynchronised crossing one level "
                    "down, which is how  hid" % (mod, port, SYNC_MODULE, mod))

    print("FILE  %s" % path)
    print("SYNC  %s (quads=%d)" % (sync_src, quads))
    print("TOTAL %d BAD %d" % (n_total, n_bad))
    return 1 if n_bad else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", default=None,
                    help="default: ../dcmac_mac_group.sv (the REAL artifact)")
    ap.add_argument("--quads", type=int, default=2)
    ap.add_argument("--sync-src", default=None)
    a = ap.parse_args()
    return check(a.file, a.quads, a.sync_src)

if __name__ == "__main__":
    sys.exit(main())
