#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_matrix_seam_boundary.sh
# Description : Runs the client boundary sets across their geometries.
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

read -r -d '' PINS <<'EOF'
c279b76fec50a214f1bcfa68c1a94c79  Makefile
9d5ea79a99b260e49e456834de164b92  run_matrix.sh
a534c31c6cf4614f2789f1cf54f18395  run_mutations.py
71beb2519cdae7a728b088470014e6ff  seg_bfm.py
f5b2ca1a9abd39769247ab9a82e2eaec  test_dcmac_axis_adapter.py
EOF

bad=0; n=0
echo "===  pin: the single-client suite must be BYTE-IDENTICAL ==="
while read -r want file; do
  [ -n "${file:-}" ] || continue
  n=$((n + 1))
  if [ ! -f "$file" ]; then
    echo "BAD  $file: MISSING"; bad=$((bad + 1)); continue
  fi
  got=$(md5sum "$file" | awk '{print $1}')
  if [ "$got" = "$want" ]; then
    echo "OK   $file  $got"
  else
  echo "BAD  $file  $got != $want  *  VIOLATED: a single-client file was modified"
    bad=$((bad + 1))
  fi
done <<< "$PINS"
echo "TOTAL $n BAD $bad"
if [ "$bad" -ne 0 ]; then
  echo " RESULT: FAIL (pin)"
  exit 2
fi

if [ "${1:-}" = "--pin-only" ]; then
  echo " RESULT: PASS (pin only; the matrices were not run)"
  exit 0
fi

echo
echo "===  regression: the single-client matrix (expect 384 testcase-runs, 0 failures) ==="
single_log=${LOGDIR_SINGLE:-logs}/ns16_single.txt
mkdir -p "$(dirname "$single_log")"
./run_matrix.sh > "$single_log" 2>&1; single_rc=$?
single_line=$(grep -E '^TOTAL testcase-runs=' "$single_log" | tail -1)
echo "  $single_line"
single_total=$(sed -n 's/^TOTAL testcase-runs=\([0-9]*\).*/\1/p' <<< "$single_line")
single_fails=$(sed -n 's/.*FAILURES=\([0-9]*\).*/\1/p' <<< "$single_line")
: "${single_total:=0}" "${single_fails:=1}"

ns16_ok=1
[ "$single_total" = "384" ] || { echo "  *  VIOLATED: $single_total testcase-runs, expected 384"; ns16_ok=0; }
[ "$single_fails" = "0" ]   || { echo "  *  VIOLATED: $single_fails failures, expected 0"; ns16_ok=0; }
[ "$single_rc" -eq 0 ]      || { echo "  *  VIOLATED: run_matrix.sh exited $single_rc"; ns16_ok=0; }

echo
echo "=== the 2-client matrix (arithmetic expectation: 8 variants x 2 seeds x 10 tests = 160) ==="
dual_log=${LOGDIR_DUAL:-logs_dual}/ns16_dual.txt
mkdir -p "$(dirname "$dual_log")"
./run_matrix_dual.sh > "$dual_log" 2>&1; dual_rc=$?
dual_line=$(grep -E '^VARIANTS=' "$dual_log" | tail -1)
echo "  $dual_line"

echo
echo "SINGLE: total=$single_total failures=$single_fails rc=$single_rc"
echo "DUAL         : $dual_line rc=$dual_rc"
if [ "$ns16_ok" -eq 1 ] && [ "$dual_rc" -eq 0 ]; then
  echo " RESULT: PASS  (single-client suite byte-identical AND 384/0; dual gate green)"
  exit 0
fi
echo " RESULT: FAIL"
exit 1
