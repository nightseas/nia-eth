#!/usr/bin/env python3
"""Every stage of the flow shall default a variable to the same value.

build_ip.tcl and build_image.tcl each read NIA_PKTGEN and each carry a default. When the two
disagree the image is built for one flow and the IP for the other, and the failure is
'module nia_fifo_cdc_512x1 not found' at synthesis after the IP stage reported success. That
happened when the image default moved to axis and the IP default stayed at seg.
"""

import re
import sys
from pathlib import Path

VARS = ("NIA_PKTGEN", "NIA_RATE", "NIA_CLIENTS", "NIA_USR_MHZ", "NIA_ADAPTER")
# A default that the rate decides is an expression rather than a literal, so it is
# compared as text. NIA_GAUI is the only one: 1 at 100, 4 at 400 and 2 at 200.
RATE_DEFAULTS = ("gaui_default",)
SCRIPTS = ("example/TU03/fpga/build_ip.tcl", "example/TU03/fpga/build_image.tcl")


def defaults_of(text):
    found = {}
    for m in re.finditer(r"\[expr \{\[info exists (?:::)?env\((\w+)\)\][^:]*:\s*"
                         r"(\"[^\"]*\"|\{[^}]*\}|[\w.]+)\s*\}\]", text):
        found.setdefault(m.group(1), m.group(2).strip('"{} '))
    return found


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    seen = {}
    for rel in SCRIPTS:
        p = root / rel
        if not p.exists():
            print("BAD  %s is absent" % rel)
            return 1
        for var, val in defaults_of(p.read_text()).items():
            if var in VARS:
                seen.setdefault(var, []).append((rel, val))
    bad = 0
    for name in RATE_DEFAULTS:
        texts = {}
        for rel in SCRIPTS:
            m = re.search(r"^set %s\s+(.*)$" % name, (root / rel).read_text(), re.M)
            texts[rel] = m.group(1).strip() if m else None
        if None in texts.values():
            print("BAD  %s is absent from %s" % (
                name, ", ".join(r for r, v in texts.items() if v is None)))
            bad += 1
        elif len(set(texts.values())) > 1:
            print("BAD  %s disagrees: %s" % (
                name, ", ".join("%s=%s" % (r, v) for r, v in texts.items())))
            bad += 1
        else:
            print("OK   %s is %s in %d script(s)" % (
                name, next(iter(texts.values())), len(texts)))
    for var, entries in sorted(seen.items()):
        vals = {v for _, v in entries}
        if len(vals) > 1:
            print("BAD  %s defaults disagree: %s" % (
                var, ", ".join("%s=%s" % (r, v) for r, v in entries)))
            bad += 1
        elif len(entries) > 1:
            print("OK   %s defaults to %s in %d script(s)" % (var, entries[0][1], len(entries)))
    print("gate_flow_defaults: %d shared variable(s), %d disagreement(s)" % (len(seen), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
