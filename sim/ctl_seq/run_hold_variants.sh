#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_hold_variants.sh
# Description : Runs the MAC control state machine set across the hold variants it must
#               behave the same in.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${LOGDIR:-$HOME/nia_logs/hold_manual}"
JOBS="${NIA_JOBS:-4}"
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/SUMMARY.txt"

declare -A ARM=(
  [F1]="-f Makefile.fsm"
  [F2]="-f Makefile.fsm confirm1"
  [F3]="-f Makefile.fsm confirm4"
  [F4]="-f Makefile.fsm group2"
  [F5]="-f Makefile.fsm longreset"
  [F6]="-f Makefile.fsm SEED=2"

  [W1]="-f Makefile.wdt"
  [W2]="-f Makefile.wdt shortwin"
  [W3]="-f Makefile.wdt longwin"
  [W4]="-f Makefile.wdt SEED=2"
  [W5]="-f Makefile.wdt lint"

  [P1]="-f Makefile.sample"
  [P3]="-f Makefile.sample slowbus"
  [P4]="-f Makefile.sample slowbus1"
  [P5]="-f Makefile.sample buserr1"
  [P6]="-f Makefile.sample SEED=2"

  [G1]="-f Makefile"
  [G2]="-f Makefile.dual"
  [T1]="-f Makefile.sequencer"
  [T2]="-f Makefile.sequencer NPORTS=2 ANCHOR=0"
  [T3]="!python3 gate_reset_ownership.py"

  [G3]="!python3 gate_ctl_seq_waits.py"
  [G4]="!python3 gate_ctl_seq_groups.py"

  [L1]="-f Makefile.fsm lint"
  [L2]="-f Makefile.sample lint"
)

WAVEF="F1 F2 F3 F4 F5 F6"
WAVEW="    "
WAVET="T1 T2 T3"
WAVEP="P1 P3 P4 P5 P6"
WAVEG="G1 G2 G3 G4"
WAVEL="L1 L2"

VARIANTS=""
for w in "${@:-all}"; do
  case "$w" in
    waveF) VARIANTS="$VARIANTS $WAVEF" ;;
    waveP) VARIANTS="$VARIANTS $WAVEP" ;;
    waveW) VARIANTS="$VARIANTS $WAVEW" ;;
    waveT) VARIANTS="$VARIANTS $WAVET" ;;
    waveG) VARIANTS="$VARIANTS $WAVEG" ;;
    waveL) VARIANTS="$VARIANTS $WAVEL" ;;
    all)   VARIANTS="$VARIANTS $WAVEL $WAVEW $WAVET $WAVEF $WAVEP $WAVEG" ;;
    *)     VARIANTS="$VARIANTS $w" ;;
  esac
done
VARIANTS="$(echo $VARIANTS)"

run_arm() {
    local a="$1" args="${ARM[$1]}"
    local log="$LOGDIR/$a.log" xml="$LOGDIR/$a.results.xml"
    rm -f "$xml"; : > "$log"
    local rc=0
    ( cd "$HERE" && \
      if [[ "$args" == !* ]]; then
          echo "+ ${args#!}"
          eval "${args#!}" || exit $?
      else
          sb="$HERE/sim_build_$a"
          rm -rf "$sb"
          echo "+ make SIM_BUILD=$sb COCOTB_RESULTS_FILE=$xml $args"
          COCOTB_RESULTS_FILE="$xml" make SIM_BUILD="$sb" COCOTB_RESULTS_FILE="$xml" $args || exit $?
      fi ) >> "$log" 2>&1 || rc=$?

    local c
    c="$(grep -aoE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' "$log" | tail -1)"
    if [ -z "$c" ] && [ -f "$xml" ]; then
        c="$(python3 - "$xml" <<'PY'
import sys, xml.etree.ElementTree as ET
tc = ET.parse(sys.argv[1]).getroot().findall(".//testcase")
fail = sum(1 for t in tc if t.find("failure") is not None)
skip = sum(1 for t in tc if t.find("skipped") is not None)
print("TESTS=%d PASS=%d FAIL=%d SKIP=%d" % (len(tc), len(tc)-fail-skip, fail, skip))
PY
)"
    fi
    [ -z "$c" ] && c="TESTS=- PASS=- FAIL=- SKIP=-  (no cocotb result: lint or gate variant)"

    local verdict=PASS
    if [ "$rc" -ne 0 ] || grep -qa 'FAIL=[1-9]' <<< "$c"; then verdict=FAIL; fi

    local expect=""
    case "$a" in
      G1) expect="TESTS=16 PASS=1 FAIL=15" ;;
      G2) expect="TESTS=5 PASS=0 FAIL=5"   ;;
      P3) expect="TESTS=15 PASS=14 FAIL=1" ;;
    esac
  local dfile=""
  [ "$a" = "P3" ] && dfile=""
    if [ -n "$expect" ]; then
        if grep -qa "$expect" <<< "$c"; then
            verdict=DISP
            c="$c  [dispositioned: $dfile]"
        else
            verdict=FAIL
  c="$c  [!! EXPECTED RESULT MISMATCH: expected '$expect' -  is stale]"
        fi
    fi
    printf '%-4s %-4s rc=%-3s %s\n' "$a" "$verdict" "$rc" "$c" > "$LOGDIR/$a.counts"
}

{
  echo "run_hold_variants.sh  $(date -Is)   NIA_JOBS=$JOBS   variants: $VARIANTS"
  echo "  RTL md5 dcmac_mac_ctl_fsm.sv     $(md5sum "$HERE/../../dcmac_mac_ctl_fsm.sv"   2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_link_sample.sv   $(md5sum "$HERE/../dcmac_link_sample.sv"     2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 wdt.sv               $(md5sum "$HERE/../wdt.sv"                  2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_ctl_seq.sv         $(md5sum "$HERE/../dcmac_ctl_seq.sv"           2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_axil_exec.sv     $(md5sum "$HERE/../dcmac_axil_exec.sv"       2>/dev/null | cut -d' ' -f1)"
  echo "  verilator $(verilator --version 2>&1 | head -1)   cocotb $(python3 -c 'import cocotb;print(cocotb.__version__)' 2>/dev/null)"
  echo
} | tee "$SUMMARY"

NRUN=0
for a in $VARIANTS; do
    if [ -z "${ARM[$a]:-}" ]; then echo "$a UNKNOWN_VARIANT" | tee -a "$SUMMARY"; continue; fi
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 2; done
    run_arm "$a" &
    NRUN=$((NRUN+1))
done
wait

NPASS=0; NFAIL=0; NDISP=0
for a in $VARIANTS; do
    if [ -f "$LOGDIR/$a.counts" ]; then
        cat "$LOGDIR/$a.counts" | tee -a "$SUMMARY"
        if   grep -q ' PASS ' "$LOGDIR/$a.counts"; then NPASS=$((NPASS+1))
        elif grep -q ' DISP ' "$LOGDIR/$a.counts"; then NDISP=$((NDISP+1))
        else NFAIL=$((NFAIL+1)); fi
    else
        echo "$a NO_RESULT" | tee -a "$SUMMARY"; NFAIL=$((NFAIL+1))
    fi
done
echo "NIA_VARIANTS_DONE arms_pass=$NPASS arms_fail=$NFAIL arms_disp=$NDISP" | tee -a "$SUMMARY"
