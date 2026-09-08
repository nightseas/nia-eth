#!/usr/bin/env python3
"""The done mask of a configuration shall equal the pattern its PHY wrapper drives.

dcmac_ctl_seq compares gt_rx_reset_done against DONE_MASK for equality, and a PHY wrapper
drives one bit per data lane of a client replicated over the eight bit quad field. The two
are written in different files and the constants are named by rate while the wrappers
replicate by lane count, so the names do not correspond: a 400GAUI-4 client drives 8'h03
and takes DONEMASK_100G, and a 200GAUI-4 client drives 8'h0F and takes DONEMASK_200G.

Setting 200GAUI-4 to DONEMASK_400G because the name carried the lane count produced an
equality that can never hold, so the reset done poll timed out on every attempt and
bring-up halted with no carrier. Nothing in the flow objected: it elaborates, it meets
timing, and it programs.
"""

import re
import sys
from pathlib import Path

TOP = "example/TU03/fpga/rtl/fpga_axispg_dual_top.sv"
PKG = "rtl/ctl/dcmac_ctl_pkg.sv"

# Each configuration names the wrapper the rate selects, taken from nia_dp_pol_rate_phy in
# ip/dcmac_polarity.tcl, and the mask the device top selects for it.
CONFIGS = (
    ("100GAUI-1", 100, 1, "rtl/dcmac_phy_wrapper.sv"),
    ("200GAUI-2", 200, 2, "rtl/rate/dcmac_phy_wrapper_200g.sv"),
    ("200GAUI-4", 200, 4, "rtl/rate/dcmac_phy_wrapper_200g.sv"),
    ("400GAUI-4", 400, 4, "rtl/rate/dcmac_phy_wrapper_400g.sv"),
)


def mask_values(root):
    text = (root / PKG).read_text()
    out = {}
    for m in re.finditer(r"localparam\s+logic\s*\[7:0\]\s+(DONEMASK_\w+)\s*=\s*8'h([0-9A-Fa-f]+)",
                         text):
        out[m.group(1)] = int(m.group(2), 16)
    return out


def driven_pattern(path):
    """Return the value a wrapper drives into one client's eight bit field."""
    text = path.read_text()
    m = re.search(r"gt_rx_reset_done\[8\*\w+ \+: 8\]\s*=\s*\{\s*(\d+)'d0\s*,\s*"
                  r"\{\s*(\d+)\s*\{", text)
    if not m:
        return None
    zeros, ones = int(m.group(1)), int(m.group(2))
    if zeros + ones != 8:
        return None
    return (1 << ones) - 1


def split_ternary(expr):
    """Split 'cond ? a : b' at its outermost question mark, respecting parentheses."""
    depth = 0
    q = -1
    for i, ch in enumerate(expr):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "?" and depth == 0 and q < 0:
            q = i
        elif ch == ":" and depth == 0 and q >= 0:
            return expr[:q], expr[q + 1:i], expr[i + 1:]
    return None


def to_python(expr):
    """Convert a Verilog ternary chain to a Python conditional expression."""
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")") and split_ternary(expr) is None:
        inner = expr[1:-1]
        if inner.count("(") != inner.count(")"):
            break
        expr = inner.strip()
    parts = split_ternary(expr)
    if parts is None:
        return expr.replace("&&", " and ").replace("||", " or ")
    cond, a, b = parts
    cond = cond.replace("&&", " and ").replace("||", " or ")
    return "(%s) if (%s) else (%s)" % (to_python(a), cond, to_python(b))


def selected_mask(root, rate, gaui):
    """Evaluate the DONE_MASK expression of the device top for one configuration."""
    text = (root / TOP).read_text()
    m = re.search(r"localparam\s+logic\s*\[7:0\]\s+DONE_MASK\s*=(.*?);", text, re.S)
    if not m:
        return None, "no DONE_MASK localparam in %s" % TOP
    expr = " ".join(m.group(1).split()).replace("dcmac_ctl_pkg::", "")
    try:
        names = mask_values(root)
        value = eval(to_python(expr), {"__builtins__": {}},  # noqa: S307
                     dict(names, RATE=rate, GAUI=gaui))
    except Exception as exc:
        return None, "cannot evaluate the DONE_MASK expression: %s" % exc
    if not isinstance(value, int) or isinstance(value, bool):
        return None, "the DONE_MASK expression did not evaluate to a mask: %r" % (value,)
    return value, None


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = 0
    checked = 0
    for name, rate, gaui, wrapper in CONFIGS:
        wpath = root / wrapper
        if not wpath.exists():
            print("SKIP %-10s %s is absent from this checkout" % (name, wrapper))
            continue
        driven = driven_pattern(wpath)
        if driven is None:
            print("BAD  %-10s %s drives no recognised reset done pattern" % (name, wrapper))
            bad += 1
            continue
        mask, err = selected_mask(root, rate, gaui)
        if err:
            print("BAD  %-10s %s" % (name, err))
            bad += 1
            continue
        checked += 1
        if mask != driven:
            print("BAD  %-10s RATE %d GAUI %d: the top selects 8'h%02X and %s drives 8'h%02X, "
                  "and dcmac_ctl_seq compares them for equality"
                  % (name, rate, gaui, mask, Path(wrapper).name, driven))
            bad += 1
        else:
            print("OK   %-10s RATE %d GAUI %d: mask 8'h%02X matches %s"
                  % (name, rate, gaui, mask, Path(wrapper).name))
    print("gate_done_mask_matches_phy: %d configuration(s) checked, %d mismatch(es)"
          % (checked, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
