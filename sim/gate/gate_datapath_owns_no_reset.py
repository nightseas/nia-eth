#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# File        : gate_datapath_owns_no_reset.py
# Description : Checks that no data path module drives a reset of its own, because reset
#               is the control plane's to own.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Python 3
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

import re
import sys
from pathlib import Path

DATAPATH = [
    "dcmac_axis_adapter.sv",
    "dcmac_port.sv",
    "dcmac_seg_axis_adapter.sv",
    "eth_axis_dwidth.sv",
    "dcmac_axis_frame_fifo.sv",
]

CONTROL_OUTPUTS = [
    "rx_datapath_reset",
    "rx_datapath_reset_ports",
    "tx_datapath_reset",
    "core_serdes_reset",
    "ctl_tx_send_idle",
    "ctl_tx_send_lfi",
    "ctl_tx_send_rfi",
    "ctl_rx_enable",
    "ctl_rx_force_resync",
    "carrier",
    "link_reset_ack",
    "fsm_state",
]

FSM_MODULE = "dcmac_mac_ctl_fsm"


def port_directions(text):
    body = text.split(")(", 1)[-1] if ")(" in text else text
    head = body.split("endmodule", 1)[0]
    out = {}
    for line in head.splitlines():
        m = re.match(r"\s*(input|output|inout)\s+(?:wire|logic|reg)?\s*(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)", line)
        if m:
            out[m.group(2)] = m.group(1)
    return out


def instantiations(text):
    return set(re.findall(r"^\s*([a-z][a-z0-9_]*)\s+(?:#\s*\(|[iu]_\w+\s*\()", text, re.M))


def main():
    rtl = Path(sys.argv[1] if len(sys.argv) > 1 else "../../rtl").resolve()
    bad = 0
    checked = 0
    for name in DATAPATH:
        path = rtl / name
        if not path.exists():
            print(f"FAIL {name}: not found under {rtl}")
            bad += 1
            continue
        text = path.read_text()
        checked += 1
        dirs = port_directions(text)

        for sig in CONTROL_OUTPUTS:
            if dirs.get(sig) == "output":
                print(f"FAIL {name}: drives control output '{sig}'")
                bad += 1

        if dirs.get("link_up") == "output":
            print(f"FAIL {name}: drives 'link_up'")
            bad += 1

        insts = instantiations(text)
        if FSM_MODULE in insts:
            print(f"FAIL {name}: instantiates {FSM_MODULE}")
            bad += 1

        for sig in ("link_up", "tx_rst_seg", "ctl_tx_enable"):
            if name == "dcmac_axis_adapter.sv" and dirs.get(sig) != "input":
                print(f"FAIL {name}: '{sig}' is not an input")
                bad += 1

        print(f"OK   {name}: {len(dirs)} ports, no control output, no state machine")

    ctl = rtl / "ctl" / "dcmac_link_ctl.sv"
    if not ctl.exists():
        print(f"FAIL ctl/dcmac_link_ctl.sv: not found under {rtl}")
        bad += 1
    else:
        if FSM_MODULE not in instantiations(ctl.read_text()):
            print(f"FAIL ctl/dcmac_link_ctl.sv: does not instantiate {FSM_MODULE}")
            bad += 1
        else:
            print(f"OK   ctl/dcmac_link_ctl.sv: instantiates {FSM_MODULE}")
        checked += 1

    if checked == 0:
        print("FAIL gate resolved no file")
        return 1
    print(f"gate_datapath_owns_no_reset: {checked} file(s) checked, {bad} finding(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
