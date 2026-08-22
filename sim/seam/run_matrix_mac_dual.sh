#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_matrix_mac_dual.sh
# Description : Runs the MAC group set across its geometries and summarises the result of
#               each.
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

VARIANTS=(
  "nominal|EN_DPRST_SYNC=1 ANCHOR_1=1"
  "ns27_control|EN_DPRST_SYNC=0 ANCHOR_1=1"
  "ns26_fallback_slots|EN_DPRST_SYNC=1 ANCHOR_1=2"
  "ff_bram_rx_only|EN_DPRST_SYNC=1 ANCHOR_1=1 FF_BRAM=1"
)
SEEDS=(1 2)
NTESTS=7

if [ "${1:-}" = "--list" ]; then
  echo "=== variants of the MAC-level dual matrix (DUT = dcmac_mac_group) ==="
  for a in "${VARIANTS[@]}"; do printf '  %-22s %s\n' "${a%%|*}" "${a#*|}"; done
  echo "seeds: ${SEEDS[*]}  tests per variant: $NTESTS"
  echo "TOTAL testcase-runs = ${#VARIANTS[@]} x ${#SEEDS[@]} x $NTESTS = $(( ${#VARIANTS[@]} * ${#SEEDS[@]} * NTESTS ))  ARITHMETIC, NOT OBSERVED"
  exit 0
fi

xml_verdict() {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print("TEST <xml> FAIL")
    print("SUMMARY -1 -1 -1 unparseable: %s" % e)
    sys.exit(0)
tcs = list(root.iter("testcase"))
nf = ns = 0
for t in tcs:
    if t.find("failure") is not None:
        st = "FAIL"; nf += 1
    elif t.find("skipped") is not None:
        st = "SKIP"; ns += 1
    else:
        st = "PASS"
    print("TEST %s %s" % (t.get("name", "?"), st))
print("SUMMARY %d %d %d ok" % (len(tcs), nf, ns))
PY
}

fail=0; ran=0
declare -A VARIANTSET

for a in "${VARIANTS[@]}"; do
  name="${a%%|*}"; over="${a#*|}"
  for s in "${SEEDS[@]}"; do
    echo "=== ARM $name  SEED=$s  ($over) ==="

    export SIM_BUILD="sim_build_macdual_${name}_s${s}"
    export COCOTB_RESULTS_FILE="results_macdual_${name}_s${s}.xml"

    mk_rc=0
    make -f Makefile.mac_dual SEED="$s" $over || mk_rc=$?

    v_out="$(xml_verdict "$COCOTB_RESULTS_FILE")"
    echo "$v_out" | grep '^TEST ' || true
    summ="$(echo "$v_out" | grep '^SUMMARY ' | head -1)"
    n_tc="$(echo "$summ" | awk '{print $2}')"
    n_fl="$(echo "$summ" | awk '{print $3}')"
    n_sk="$(echo "$summ" | awk '{print $4}')"

    why=""
    [ "$mk_rc" -eq 0 ]      || why="$why F1(make rc=$mk_rc)"
    [ "$n_tc" != "-1" ]     || why="$why F2(results XML missing/unparseable)"
    if [ "$n_tc" != "-1" ]; then
      [ "$n_fl" -eq 0 ]     || why="$why F3($n_fl failed)"
      [ "$n_sk" -eq 0 ]     || why="$why F3($n_sk skipped)"
      [ "$n_tc" -eq "$NTESTS" ] || why="$why F4(ran $n_tc of $NTESTS -> the run DIED PART WAY)"
    fi

    if [ -z "$why" ]; then
      echo "ARM $name SEED=$s: PASS  (tests=$n_tc failures=0 skipped=0)"

    else
      echo "ARM $name SEED=$s: FAIL -$why"
      echo "  build tree KEPT for post-mortem: $SIM_BUILD"
      fail=$((fail + 1))
    fi

    VARIANTSET["${name}_s${s}"]="$(echo "$v_out" | grep '^TEST ' | sort | tr '\n' ';')"
    ran=$((ran + 1))
  done
done

echo "=== MAC-DUAL MATRIX: arms_run=$ran failed=$fail ==="

ns27_bad=0
for s in "${SEEDS[@]}"; do
  A="${VARIANTSET[nominal_s${s}]:-}"; B="${VARIANTSET[ns27_control_s${s}]:-}"
  if [ -z "$A" ] || [ -z "$B" ]; then
  echo " CROSS-VARIANT (seed $s): INDETERMINATE - one of the two variants produced no testcase list"
    ns27_bad=$((ns27_bad + 1))
  elif [ "$A" = "$B" ]; then
  echo " CROSS-VARIANT (seed $s): IDENTICAL pass/fail set for EN_DPRST_SYNC=1 vs 0 OK"
  else
  echo " CROSS-VARIANT (seed $s): DIFFERENT - EN_DPRST_SYNC altered FUNCTION, not just timing."
    echo "  EN_DPRST_SYNC=1: $A"
    echo "  EN_DPRST_SYNC=0: $B"
    ns27_bad=$((ns27_bad + 1))
  fi
done

if [ "$fail" -ne 0 ] || [ "$ns27_bad" -ne 0 ]; then
  echo "MAC-DUAL MATRIX RESULT: FAIL  (arms_failed=$fail ns27_cross_arm_problems=$ns27_bad)"
  exit 1
fi
echo "MAC-DUAL MATRIX RESULT: PASS  (arms_run=$ran, $(( ran * NTESTS )) testcase-runs, 0 failures)"
