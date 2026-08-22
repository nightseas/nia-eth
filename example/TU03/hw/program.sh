#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : program.sh
# Description : Reports the JTAG cable and the device, and writes an image over JTAG.
#               Takes check or program, and the image path in PDI.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${NIA_VIVADO_BIN:-vivado}"
PDI="${PDI:-}"
HW_URL="${HW_URL:-localhost:3121}"
DEVICE="${DEVICE:-xcvp1552_1}"
NIA_TARGET="${NIA_TARGET:-}"

usage() {
	cat <<EOF
program.sh check    report the tool, the cable and the device this shell can see
program.sh program  write PDI to the device over JTAG

  PDI        the image to write, required by program
  NIA_TARGET a substring selecting one JTAG target, for example a cable serial. Required
             whenever more than one board is attached, because the first target is
             otherwise an arbitrary choice and the wrong board would be written
  HW_URL     the hw_server URL, default localhost:3121
  DEVICE     the device name in the hardware target, default xcvp1552_1
  NIA_VIVADO_BIN  the tool executable, default vivado

Writing an image needs a Vivado or Vivado Lab install with the JTAG drivers.
A JTAG configuration survives a warm reboot; a new endpoint needs a cold one.
EOF
}

tool_check() {
	command -v "$BIN" >/dev/null || {
		echo "program: '$BIN' is not on the path. Source settings64.sh of a Vivado or Vivado Lab install."
		return 1
	}
	echo "program: tool $(command -v "$BIN")"
}

run_tcl() {
	local tcl="$1"
	shift
	"$BIN" -mode batch -nojournal -notrace -source "$tcl" -tclargs "$@"
}

case "${1:-usage}" in
check)
	tool_check
	run_tcl "$HERE/program.tcl" check "$HW_URL" "$DEVICE" "" "$NIA_TARGET"
	;;
program)
	tool_check
	[ -n "$PDI" ] || { echo "program: set PDI to the image to write"; exit 2; }
	[ -f "$PDI" ] || { echo "program: PDI=$PDI does not exist"; exit 2; }
	run_tcl "$HERE/program.tcl" program "$HW_URL" "$DEVICE" "$PDI" "$NIA_TARGET"
	;;
*)
	usage
	;;
esac
