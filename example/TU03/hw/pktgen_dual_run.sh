#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : pktgen_dual_run.sh
# Description : Runs the wire test or the cable event monitor over xsdb, in the foreground
#               or detached, and stops a detached monitor.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${NIA_XSDB_BIN:-xsdb}"
LOG_DIR="${NIA_LOG_DIR:-$PWD}"

usage() {
	cat <<EOF
pktgen_dual_run.sh test              the wire test, steps 1 to 7, in the foreground
pktgen_dual_run.sh monitor           the cable event monitor, in the foreground
pktgen_dual_run.sh monitor-detached  the monitor, detached, log path printed
pktgen_dual_run.sh linkmon           the link quality monitor, in the foreground
pktgen_dual_run.sh linkmon-detached  the link quality monitor, detached, log path printed
pktgen_dual_run.sh stop              stop a detached monitor of either kind

  the test reads NIA_STEPS, NIA_RATE_SIZES, NIA_RATE_S, NIA_BURST_SIZES, NIA_RESET_GROUP,
    NIA_REPAIR, NIA_REPAIR_LEN, NIA_LINE_GBPS
  the monitor reads NIA_DURATION_S, NIA_LEN, NIA_BURST_BYTES, NIA_AUTO_RESTART
  the link quality monitor reads NIA_MON_S, NIA_MON_DUR_S, NIA_MON_LEN, NIA_MON_LOAD, NIA_MON_CSV
  all read NIA_WINDOW, NIA_PG0, NIA_CMD, NIA_PG1
  NIA_LOG_DIR sets where a detached log is written, default the current directory

A Vivado or Vivado Lab install must be sourced, so that xsdb is on the path and the JTAG
drivers are present. The board must already carry the two client image.
EOF
}

need_tool() {
	command -v "$BIN" >/dev/null || {
		echo "run: '$BIN' is not on the path. Source settings64.sh of a Vivado or Vivado Lab install."
		exit 1
	}
}

case "${1:-usage}" in
test)
	need_tool
	"$BIN" "$HERE/pktgen_dual_test.tcl"
	;;
monitor)
	need_tool
	"$BIN" "$HERE/pktgen_dual_monitor.tcl"
	;;
monitor-detached)
	need_tool
	log="$LOG_DIR/pktgen_dual_monitor_$(date +%Y%m%d_%H%M%S).log"
	setsid nohup "$BIN" "$HERE/pktgen_dual_monitor.tcl" >"$log" 2>&1 &
	echo "run: monitor detached, pid $!"
	echo "run: log $log"
	echo "run: follow it with  tail -f $log"
	echo "run: stop it with    $0 stop"
	;;
linkmon)
	need_tool
	"$BIN" "$HERE/nia_eth_linkmon.tcl"
	;;
linkmon-detached)
	need_tool
	log="$LOG_DIR/nia_eth_linkmon_$(date +%Y%m%d_%H%M%S).log"
	setsid nohup "$BIN" "$HERE/nia_eth_linkmon.tcl" >"$log" 2>&1 &
	echo "run: link quality monitor detached, pid $!"
	echo "run: log $log"
	echo "run: follow it with  tail -f $log"
	echo "run: stop it with    $0 stop"
	;;
stop)
	stopped=0
	pkill -f pktgen_dual_monitor.tcl && stopped=1
	pkill -f nia_eth_linkmon.tcl && stopped=1
	[ "$stopped" = 1 ] && echo "run: monitor stopped" || echo "run: no monitor was running"
	;;
*)
	usage
	;;
esac
