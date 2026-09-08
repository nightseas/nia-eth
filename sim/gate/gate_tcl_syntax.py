#!/usr/bin/env python3
"""Every Tcl script in the repository shall be balanced and shall use the documented idioms.

No Tcl interpreter is present on the development machine, so a fault in a flow script is
found by the build server, and the cost is a dispatch. This gate reads the scripts as Tcl
tokens and reports an unbalanced brace, bracket or quote with the line it opened on, and it
refuses two idioms that have each cost a run:

  1. env(NAME) inside a proc. A proc has its own scope and env is global there, so the read
     shall be ::env(NAME). At file scope both forms work, which is why the fault survives
     review.
  2. A brace around a substitution, as in {${var}}. Braces suppress substitution, so the
     literal dollar sign reaches the tool.

Usage: gate_tcl_syntax.py [root]
"""

import re
import sys
from pathlib import Path

# Tcl special characters and the state machine over them
BRACE, BRACKET, QUOTE = "{", "[", '"'


class Unbalanced(Exception):
    def __init__(self, kind, line):
        super().__init__(kind)
        self.kind = kind
        self.line = line


def scan(text):
    """Walk the text as Tcl and return the stack state, raising on an imbalance.

    The scan tracks brace depth, bracket depth and quoted spans, honours backslash escapes,
    and treats a hash as a comment only where a command may begin.
    """
    stack = []  # entries are (kind, line)
    i = 0
    line = 1
    n = len(text)
    cmd_start = True  # a command may begin here, so a hash is a comment
    in_quote = False
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            if not in_quote and not any(k == BRACE for k, _ in stack):
                cmd_start = True
            continue
        if c == "\\":
            # an escape consumes the next character, and a backslash newline is a continuation
            if i + 1 < n and text[i + 1] == "\n":
                line += 1
            i += 2
            continue
        if c == "#" and cmd_start and not in_quote:
            while i < n and text[i] != "\n":
                if text[i] == "\\" and i + 1 < n and text[i + 1] == "\n":
                    line += 1
                    i += 1
                i += 1
            continue
        if c == QUOTE and not any(k == BRACE for k, _ in stack):
            # a quote inside braces is literal
            if in_quote:
                in_quote = False
                for j in range(len(stack) - 1, -1, -1):
                    if stack[j][0] == QUOTE:
                        stack.pop(j)
                        break
            else:
                in_quote = True
                stack.append((QUOTE, line))
            i += 1
            cmd_start = False
            continue
        if c == BRACE:
            stack.append((BRACE, line))
            i += 1
            cmd_start = True
            continue
        if c == "}":
            for j in range(len(stack) - 1, -1, -1):
                if stack[j][0] == BRACE:
                    stack.pop(j)
                    break
            else:
                raise Unbalanced("a closing brace with no opening brace", line)
            i += 1
            cmd_start = False
            continue
        if c == BRACKET and not any(k == BRACE for k, _ in stack):
            stack.append((BRACKET, line))
            i += 1
            cmd_start = True
            continue
        if c == "]" and not any(k == BRACE for k, _ in stack):
            for j in range(len(stack) - 1, -1, -1):
                if stack[j][0] == BRACKET:
                    stack.pop(j)
                    break
            else:
                raise Unbalanced("a closing bracket with no opening bracket", line)
            i += 1
            cmd_start = False
            continue
        if c == ";":
            cmd_start = True
            i += 1
            continue
        if not c.isspace():
            cmd_start = False
        i += 1
    if in_quote:
        opened = [ln for k, ln in stack if k == QUOTE]
        raise Unbalanced("an unterminated quoted string", opened[0] if opened else 0)
    if stack:
        kind, ln = stack[-1]
        name = {BRACE: "brace", BRACKET: "bracket", QUOTE: "quote"}[kind]
        raise Unbalanced("an unclosed %s" % name, ln)
    return True


def proc_spans(text):
    """Return the line ranges of every proc body, so a scoped read can be checked."""
    spans = []
    for m in re.finditer(r"^\s*proc\s+(\S+)", text, re.M):
        # a proc has an argument list and then a body, so the body is the second brace group
        i = text.find("{", m.end())
        if i < 0:
            continue
        depth = 0
        k = i
        while k < len(text):
            if text[k] == "\\":
                k += 2
                continue
            if text[k] == "{":
                depth += 1
            elif text[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        i = text.find("{", k + 1)
        if i < 0:
            continue
        depth = 0
        j = i
        while j < len(text):
            if text[j] == "\\":
                j += 2
                continue
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        spans.append((m.group(1), text[:i].count("\n") + 1, text[: j + 1].count("\n") + 1,
                      text[i:j + 1]))
    return spans


ABSENT_COMMANDS = ("get_cdc_violations",)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(p for p in root.rglob("*.tcl")
                   if ".git" not in p.parts and "build" not in p.parts
                   and ".srcs" not in p.parts and ".gen" not in p.parts)
    bad = 0
    checks = 0
    for p in files:
        rel = p.relative_to(root)
        text = p.read_text(errors="replace")
        checks += 1
        try:
            scan(text)
        except Unbalanced as e:
            print("BAD  %s: %s, opened on line %d" % (rel, e.kind, e.line))
            bad += 1
            continue
        faults = []
        # A command this release does not carry aborts the script where it is called. In
        # build_image.tcl get_cdc_violations was called after routing and before the device
        # image stage, so eight images reported met timing and wrote no device image.
        for n, line in enumerate(text.split("\n"), 1):
            bare = line.split("#", 1)[0]
            for cmd in ABSENT_COMMANDS:
                if cmd in bare:
                    faults.append("line %d: %s is absent from Vivado 2025.2 and aborts the"
                                  " script" % (n, cmd))
        # env inside a proc shall be ::env
        for name, l0, l1, body in proc_spans(text):
            for m in re.finditer(r"(?<!:)\benv\(", body):
                ln = l0 + body[: m.start()].count("\n")
                faults.append("line %d: proc %s reads env( and a proc scope needs ::env("
                              % (ln, name))
        # A brace around a substitution suppresses it, so the literal dollar sign reaches the
        # tool. The same form is correct as the condition of if, elseif, while, for and expr,
        # which evaluate their argument, so only the other positions are a fault.
        evaluated = ("if", "elseif", "while", "for", "expr", "&&", "||", "!")
        for m in re.finditer(r"\{\$\{\w+\}\}|\{\$\w+\}", text):
            ln = text[: m.start()].count("\n") + 1
            frag = m.group(0)
            before = text[max(0, m.start() - 40):m.start()]
            word = re.findall(r"([A-Za-z_&|!]+)\s*$", before)
            if word and word[0] in evaluated:
                continue
            if frag.startswith("{${"):
                faults.append("line %d: %s braces a substitution, so the dollar sign is literal"
                              % (ln, frag))
        if faults:
            for f in faults:
                print("BAD  %s: %s" % (rel, f))
            bad += 1
        else:
            print("OK   %s, %d line(s)" % (rel, text.count("\n") + 1))
    print("gate_tcl_syntax: %d file(s) checked, %d failing" % (checks, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
