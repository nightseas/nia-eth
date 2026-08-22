#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : program_twoboard.sh
# Description : Programs both boards of the two board bench, selecting each by JTAG cable
#               serial. Takes list, check or program, and prints the digest of each image
#               it writes.
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
HW_URL="${HW_URL:-localhost:3121}"
DEVICE="${DEVICE:-xcvp1552}"
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"

usage() {
	cat <<EOF
program_twoboard.sh list                  list every JTAG target so the two cable serials can be read
program_twoboard.sh check                 open both boards by serial and report each part
program_twoboard.sh program PDI_A [PDI_B] write PDI_A to board A and PDI_B to board B

  SERIAL_A   the JTAG cable serial of board A, required by check and program
  SERIAL_B   the JTAG cable serial of board B, required by check and program
  HW_URL     the hw_server URL, default localhost:3121
  DEVICE     the device PART to select on each target, default xcvp1552
  NIA_VIVADO_BIN  the tool executable, default vivado

PDI_B defaults to PDI_A. Both boards must carry the same rate variant: a 100G image talking to a
200G image is four lanes talking to two and will not align.

The serials name the boards, and nothing in the design does: both boards answer at the same register
aperture with the same identity, so board A is whichever cable serial is given as SERIAL_A here and as
the first DPC target to the test scripts. NIA_SWAP=1 swaps the test scripts' A and B if the two orders
disagree.

A JTAG configuration survives a warm reboot; a new endpoint needs a cold one.
EOF
}

tool_check() {
	command -v "$BIN" >/dev/null || {
		echo "program_twoboard: '$BIN' is not on the path. Source settings64.sh of a Vivado or Vivado Lab install."
		return 1
	}
	echo "program_twoboard: tool $(command -v "$BIN")"
}

run_tcl() {
	"$BIN" -mode batch -nojournal -notrace -source "$HERE/program_twoboard.tcl" -tclargs "$@"
}

require_serials() {
	[ -n "$SERIAL_A" ] || { echo "program_twoboard: set SERIAL_A to board A's JTAG cable serial"; exit 2; }
	[ -n "$SERIAL_B" ] || { echo "program_twoboard: set SERIAL_B to board B's JTAG cable serial"; exit 2; }
	[ "$SERIAL_A" != "$SERIAL_B" ] || { echo "program_twoboard: SERIAL_A and SERIAL_B are the same cable"; exit 2; }
}

case "${1:-usage}" in
list)
	tool_check
	run_tcl list "$HW_URL" "$DEVICE" "" ""
	;;
check)
	tool_check
	require_serials
	run_tcl check "$HW_URL" "$DEVICE" "$SERIAL_A" ""
	run_tcl check "$HW_URL" "$DEVICE" "$SERIAL_B" ""
	;;
program)
	tool_check
	require_serials
	PDI_A="${2:-}"
	PDI_B="${3:-$PDI_A}"
	[ -n "$PDI_A" ] || { echo "program_twoboard: give the image to write as the first argument"; exit 2; }
	[ -f "$PDI_A" ] || { echo "program_twoboard: $PDI_A does not exist"; exit 2; }
	[ -f "$PDI_B" ] || { echo "program_twoboard: $PDI_B does not exist"; exit 2; }
	echo "program_twoboard: board A serial $SERIAL_A image $PDI_A md5 $(md5sum "$PDI_A" | cut -d' ' -f1)"
	echo "program_twoboard: board B serial $SERIAL_B image $PDI_B md5 $(md5sum "$PDI_B" | cut -d' ' -f1)"
	run_tcl program "$HW_URL" "$DEVICE" "$SERIAL_A" "$PDI_A"
	run_tcl program "$HW_URL" "$DEVICE" "$SERIAL_B" "$PDI_B"
	;;
*)
	usage
	;;
esac
