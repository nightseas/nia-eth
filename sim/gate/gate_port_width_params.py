#!/usr/bin/env python3
"""A parameter that sets a port width shall be passed at every instantiation.

dcmac_seg_axis_adapter instantiated dcmac_seg_axis_rx as

    dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_rx (

while that module declares DATA_W and sizes m_axis_tdata by it. DATA_W therefore took its
default of 1024 while the bus it drove was N_SEG*SEG_W, which is 256 at that set's geometry, so
one quarter of every beat reached the bus and the receive path delivered a quarter of the bytes.
Elaboration is silent, because both sides are legal on their own.

The check reads each module's parameter list and port declarations, collects the parameters that
appear in a port width expression, and requires every named instantiation to pass them.
"""

import re
import sys
from pathlib import Path

MODULE_RE = re.compile(r"^\s*module\s+(\w+)\s*#?\s*\(", re.M)
PARAM_RE = re.compile(r"parameter\s+(?:type\s+)?(?:int|integer|logic|bit|byte)?"
                      r"(?:\s+unsigned|\s+signed)?(?:\s*\[[^\]]*\])?\s*(\w+)\s*=")
PORT_RE = re.compile(r"^\s*(?:input|output|inout)\s+"
                     r"(?:wire|logic|reg)?\s*(?:signed|unsigned)?\s*\[([^\]]*)\]", re.M)


def module_spans(text):
    """Yield (name, header_text, body_text) for each module in the file."""
    out = []
    for m in MODULE_RE.finditer(text):
        name = m.group(1)
        end = text.find("endmodule", m.end())
        if end < 0:
            end = len(text)
        block = text[m.start():end]
        # The header runs to the closing parenthesis of the port list, which is the first
        # ");" at the start of a line.
        hm = re.search(r"^\s*\);\s*$", block, re.M)
        header = block[:hm.end()] if hm else block
        out.append((name, header, block))
    return out


def width_parameters(header):
    """The parameters of this module that appear inside a port width expression."""
    params = set(PARAM_RE.findall(header))
    if not params:
        return set(), set()
    widths = " ".join(PORT_RE.findall(header))
    used = {p for p in params if re.search(r"\b%s\b" % re.escape(p), widths)}
    return params, used


def instantiations(text, name):
    """Yield (line_number, passed_parameter_names) for each instantiation of name."""
    out = []
    for m in re.finditer(r"^[ \t]*%s\s*#\s*\(" % re.escape(name), text, re.M):
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = text[m.end():i]
        passed = set(re.findall(r"\.\s*(\w+)\s*\(", block))
        out.append((text[: m.start()].count("\n") + 1, passed))
    return out


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    sources = sorted(p for p in list(root.glob("rtl/**/*.sv")) + list(root.glob("sim/tb/*.sv"))
                     + list(root.glob("example/**/rtl/*.sv"))
                     if ".git" not in p.parts and "build" not in p.parts)

    declared = {}
    for p in sources:
        text = p.read_text(errors="replace")
        for name, header, _ in module_spans(text):
            params, used = width_parameters(header)
            if used:
                declared[name] = (used, p.relative_to(root))

    # The omissions present when this check was written are listed in the baseline, because each
    # takes a default that matches its context. A new one is a fault: the same omission on
    # dcmac_seg_axis_rx cost a quarter of every receive beat.
    baseline = set()
    bl = root / "sim/gate/port_width_params_baseline.txt"
    if bl.exists():
        for line in bl.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                baseline.add(line)

    bad = 0
    checked = 0
    accepted = 0
    for p in sources:
        text = p.read_text(errors="replace")
        rel = p.relative_to(root)
        for name, (needed, _) in declared.items():
            for line, passed in instantiations(text, name):
                checked += 1
                missing = sorted(needed - passed)
                if missing:
                    key = "%s %s %s" % (rel, name, ",".join(missing))
                    if key in baseline:
                        accepted += 1
                        continue
                    print("BAD  %s line %d: %s takes its default for %s, and that parameter"
                          " sets a port width" % (rel, line, name, ", ".join(missing)))
                    bad += 1

    print("gate_port_width_params: %d module(s) with width bearing parameters,"
          " %d instantiation(s) checked, %d accepted by the baseline, %d failing"
          % (len(declared), checked, accepted, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
