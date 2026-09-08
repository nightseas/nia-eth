#!/usr/bin/env python3
"""A Tcl name shall be a scalar or an array in one script, and not both.

Tcl raises "can't set x(field): variable isn't array" when `array set x` runs on a name that
already holds a scalar. In a script whose steps are selectable, the two uses can sit in
different steps and the abort appears only when both steps run in one invocation.

example/TU03/hw/pktgen_dual_test.tcl carried three such names. `a0` and `a1` were scalars in
step 1, the window alias check, and arrays in step 6, the per burst counters, so every run that
selected both steps aborted after step 6's third verdict. `s0` was an array in step 1 and a
scalar in step 2. The whole seven step test could not complete for as long as the collision
stood, whatever the device did.
"""

import re
import sys
from pathlib import Path

SET_RE = re.compile(r'^\s*set\s+([A-Za-z_]\w*)\s', re.M)
ARRAY_RE = re.compile(r'^\s*array\s+set\s+([A-Za-z_]\w*)\s', re.M)


def collisions(text):
    return sorted(set(ARRAY_RE.findall(text)) & set(SET_RE.findall(text)))


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(p for p in root.rglob("*.tcl") if ".git" not in p.parts)
    bad = 0
    for p in files:
        try:
            text = p.read_text(errors="replace")
        except OSError as exc:
            print("BAD  %s cannot be read: %s" % (p.relative_to(root), exc))
            bad += 1
            continue
        hits = collisions(text)
        if hits:
            print("BAD  %s uses %s as both a scalar and an array"
                  % (p.relative_to(root), ", ".join(hits)))
            bad += 1
    print("gate_tcl_var_kind: %d file(s) checked, %d with a name of both kinds"
          % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
