#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_matrix_dual.sh
# Description : Runs the two client set across its geometries.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u
set -o pipefail
cd "$(dirname "$0")"
export PATH=$HOME/local/bin:$HOME/.local/bin:$PATH
LOGDIR=${LOGDIR:-logs_dual}
mkdir -p "$LOGDIR"
SEEDS=${SEEDS:-"1 2"}
SUITE=test_dcmac_dual.py
EXPECT_TESTS=${EXPECT_TESTS:-10}
rc=0; total=0; fails=0; skips=0; variants=0; shortfall=0

declared=$(grep -c '^@cocotb.test' "$SUITE" || true)
defined=$(grep -c '^async def test_' "$SUITE" || true)
echo "SUITE $SUITE: @cocotb.test=$declared  async def test_=$defined  EXPECT_TESTS=$EXPECT_TESTS"
if [ "$declared" -ne "$EXPECT_TESTS" ] || [ "$defined" -ne "$EXPECT_TESTS" ]; then
  echo " SUITE COUNT MISMATCH - the suite does not define EXPECT_TESTS tests. Fix EXPECT_TESTS (and"
  echo "  run_mutations_dual.py's expect lists) or restore the test. Refusing to run: a matrix whose"
  echo "  expected count is wrong reports either phantom SHORT VARIANTS or a silently shrunken suite."
  echo "RESULT: FAIL"
  echo "EXIT=2"
  exit 2
fi

verdict () {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("0 1 0 no-xml"); sys.exit(0)
tcs = list(root.iter('testcase'))
if not tcs:
    print("0 1 0 no-testcases"); sys.exit(0)
bad = [c for c in tcs if len(list(c))]
skipped = [c for c in bad if c.find('skipped') is not None]
tags = sorted({ch.tag for c in bad for ch in c})
names = ",".join(c.get('name', '?') for c in bad) or "-"
print(f"{len(tcs)} {len(bad)} {len(skipped)} {'|'.join(tags) or '-'}:{names}")
PY
}

run_one () {
  local tag="$1"; shift
  echo "=== $tag ==="

  export SIM_BUILD="sim_build_dual_${tag}"
  rm -rf "$SIM_BUILD" >/dev/null 2>&1 || true
  make -f Makefile.dual "$@" COCOTB_RESULTS_FILE="$LOGDIR/results_${tag}.xml" \
       > "$LOGDIR/dual_${tag}.log" 2>&1 || rc=1

  local t=0 f=1 s=0 why="verdict-did-not-run"
  read -r t f s why < <(verdict "$LOGDIR/results_${tag}.xml") || true
  total=$((total + t)); fails=$((fails + f)); skips=$((skips + s)); variants=$((variants + 1))

  if [ "$t" -ne "$EXPECT_TESTS" ]; then
  echo "  SHORT ARM: tests=$t expected=$EXPECT_TESTS - the variant did not run to completion"
    shortfall=$((shortfall + 1)); rc=1
  fi
  echo "  tests=$t failures=$f skipped=$s   log=$LOGDIR/dual_${tag}.log"
  [ "$f" -eq 0 ] || { echo "   FAILED: $why"; rc=1; }
  [ "$s" -eq 0 ] || { echo "   SKIPPED TESTS PRESENT - a skip is a gate failure here"; rc=1; }
}

for s in $SEEDS; do
  run_one "dual_nom_seed${s}"    SEED="$s" TX_MHZ=250 RX_MHZ=250 ANCHOR_C0=0 ANCHOR_C1=1
  run_one "anchor02_seed${s}"    SEED="$s" TX_MHZ=250 RX_MHZ=250 ANCHOR_C0=0 ANCHOR_C1=2
  run_one "nports2_seed${s}"     SEED="$s" TX_MHZ=250 RX_MHZ=250 \
                                 NPORTS_C0=2 ANCHOR_C0=0 NPORTS_C1=2 ANCHOR_C1=2
  run_one "xclk_seed${s}"        SEED="$s" TX_MHZ=200 RX_MHZ=322.265625
  run_one "tx322_rx322_seed${s}" SEED="$s" TX_MHZ=322.265625 RX_MHZ=322.265625
  run_one "slowrx_seed${s}"      SEED="$s" TX_MHZ=250 RX_MHZ=50
  run_one "ffrx_seed${s}"        SEED="$s" TX_MHZ=250 RX_MHZ=250 FF_BRAM=1
  run_one "ptp_seed${s}"         SEED="$s" TX_MHZ=250 RX_MHZ=250 PTP_TS_EN=1 TX_TAG_W=16
done

echo "VARIANTS=$variants  TOTAL testcase-runs=$total  FAILURES=$fails  SKIPPED=$skips  SHORT_ARMS=$shortfall"
if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ] && [ "$fails" -eq 0 ] && [ "$skips" -eq 0 ] \
   && [ "$shortfall" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  rc=1
fi
echo "EXIT=$rc"
exit $rc
