#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_matrix.sh
# Description : Runs the adapter set across the geometries it must hold at, and reports
#               one line per geometry.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u
cd "$(dirname "$0")"
export PATH=$HOME/local/bin:$HOME/.local/bin:$PATH
LOGDIR=${LOGDIR:-logs}
mkdir -p "$LOGDIR"
SEEDS=${SEEDS:-"1 2"}
rc=0; total=0; fails=0

verdict () {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("0 1"); sys.exit(0)
tcs = list(root.iter('testcase'))
bad = [c for c in tcs if len(list(c))]
print(f"{len(tcs)} {len(bad) if tcs else 1}")
PY
}

run_one () {
  local tag="$1"; shift
  echo "=== $tag ==="
  make -s clean >/dev/null 2>&1
  make "$@" COCOTB_RESULTS_FILE="$LOGDIR/results_${tag}.xml" \
       > "$LOGDIR/core_${tag}.log" 2>&1 || rc=1
  read -r t f < <(verdict "$LOGDIR/results_${tag}.xml")
  total=$((total + t)); fails=$((fails + f))
  echo "  tests=$t failures=$f   log=$LOGDIR/core_${tag}.log"
  [ "$f" -eq 0 ] || rc=1
}

for s in $SEEDS; do
  run_one "tx250_rx250_seed${s}" SEED="$s" TX_MHZ=250        RX_MHZ=250
  run_one "tx200_rx200_seed${s}" SEED="$s" TX_MHZ=200        RX_MHZ=200
  run_one "tx322_rx322_seed${s}" SEED="$s" TX_MHZ=322.265625 RX_MHZ=322.265625
  run_one "xclk_seed${s}"        SEED="$s" TX_MHZ=200        RX_MHZ=322.265625
  run_one "nports4_seed${s}"     SEED="$s" TX_MHZ=250 RX_MHZ=250 NPORTS=4
  run_one "ffrx_seed${s}"        SEED="$s" TX_MHZ=250 RX_MHZ=250 FF_BRAM=1
  run_one "ffboth_seed${s}"      SEED="$s" TX_MHZ=250 RX_MHZ=250 FF_BRAM=1 TX_FF_BRAM=1
  run_one "ptp_seed${s}"         SEED="$s" TX_MHZ=250 RX_MHZ=250 PTP_TS_EN=1 TX_TAG_W=16
done

echo "TOTAL testcase-runs=$total  FAILURES=$fails"
if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ] && [ "$fails" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit $rc
