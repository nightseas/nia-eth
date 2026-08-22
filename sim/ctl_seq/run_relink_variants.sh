#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_relink_variants.sh
# Description : Runs the control plane set across the relink variants, which are the
#               outage lengths recovery must survive.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${LOGDIR:-$HOME/nia_logs/relink}"
SUMMARY="$LOGDIR/SUMMARY.txt"
JOBS="${NIA_JOBS:-1}"
mkdir -p "$LOGDIR"

VLVER="$(verilator --version 2>&1 | awk '{print $2}')"
case "$VLVER" in
  5.*) : ;;
  *) echo "NIA_ABORT run_relink_variants.sh: verilator is $VLVER at $(command -v verilator); cocotb needs >= 4.106 and the build server has 5.026 at ~/local/bin. Set PATH and re-dispatch. No variant was run."; exit 3;;
esac

declare -A ARM=(
  [A1]="-f Makefile.wdt_register"
  [A2]="-f Makefile.wdt_register dual"
  [A3]="-f Makefile.wdt_register narrow"
  [A4]="-f Makefile.wdt_register SEED=2"
  [A5]="-f Makefile.wdt_register lint"
  [A6]="-f Makefile.statidx"
  [A7]="-f Makefile.statidx defaultmax"

  [B1]="-f Makefile"
  [B2]="-f Makefile.dual"
  [B3]="-f Makefile.dual N_GROUP=2 NPORTS=2 ANCHOR_1=2"
  [B4]="-f Makefile SEED=2"
  [B5]="-f Makefile.link_ctl"
  [B6]="-f Makefile.link_ctl single"
  [B7]="-f Makefile.link_ctl rxonly"
  [B8]="-f Makefile.link_ctl stage2"
  [B9]="-f Makefile.link_ctl confirm1"
  [B10]="-f Makefile.link_ctl wide"
  [B11]="-f Makefile.link_ctl SEED=2"
  [B12]="-f Makefile.link_ctl lint"

  [S1]="-f Makefile.wdt"
  [S2]="-f Makefile.wdt rxonly"
  [S3]="-f Makefile.wdt confirm1"
  [S4]="-f Makefile.wdt confirm3"
  [S5]="-f Makefile.wdt slowbus"
  [S6]="-f Makefile.wdt SEED=2"
  [S7]="-f Makefile.wdt lint"
  [S8]="-f Makefile.exec"
  [S9]="-f Makefile.exec nopri"
  [S10]="-f Makefile.exec five"
  [S11]="-f Makefile.exec notmo"
  [S12]="-f Makefile.exec SEED=2"
  [S13]="-f Makefile.exec lint"

  [C1]="@../../sim|!OPT_FAST=-O0 ./run_matrix_mac_dual.sh"
  [C2]="@../../sim|!OPT_FAST=-O0 make -f Makefile.mac_dual ESC_MAX_STAGE=1 SIM_BUILD=$PWD/sim_build_C2"
  [C3]="@../../sim|!OPT_FAST=-O0 make -f Makefile.mac_dual ESC_MAX_STAGE=2 SIM_BUILD=$PWD/sim_build_C3"

  [M1]="!python3 run_supervisor_mutations.py"

)

WAVEA="A1 A2 A3 A4 A5 A6 A7"
WAVEB="B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12"
WAVES="S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13"
WAVEC="C1 C2 C3"
WAVEM="M1"

case "${1:-all}" in
  waveA) VARIANTS="$WAVEA" ;;
  waveB) VARIANTS="$WAVEB" ;;
  waveS) VARIANTS="$WAVES" ;;
  waveC) VARIANTS="$WAVEC" ;;
  waveM) VARIANTS="$WAVEM" ;;
  all)   VARIANTS="$WAVEA $WAVEB $WAVES $WAVEC $WAVEM" ;;
  *)     VARIANTS="$*" ;;
esac

run_arm() {
    local a="$1" args="${ARM[$1]}"
    local log="$LOGDIR/$a.log" xml="$LOGDIR/$a.results.xml"
    rm -f "$xml"
    : > "$log"
    local rc=0
    IFS=';' read -ra parts <<< "$args"
    local dir="$HERE"
    if [[ "$args" == @* ]]; then
        dir="$HERE/${args%%|*}"; dir="${dir/@/}"
        args="${args#*|}"
        IFS=';' read -ra parts <<< "$args"
    fi
    local i=0
    ( cd "$dir" && for p in "${parts[@]}"; do
          [ -z "${p// }" ] && continue
          i=$((i+1))
          sb="$HERE/sim_build_${a}_$i"
          rm -rf "$sb"
          if [[ "$p" == !* ]]; then
              echo "+ ${p#!}"
              eval "${p#!}" || exit $?
          else
              echo "+ make SIM_BUILD=$sb COCOTB_RESULTS_FILE=$xml $p"
              COCOTB_RESULTS_FILE="$xml" make SIM_BUILD="$sb" COCOTB_RESULTS_FILE="$xml" $p || exit $?
          fi
      done ) >> "$log" 2>&1 || rc=$?

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
    [ -z "$c" ] && c="TESTS=- PASS=- FAIL=- SKIP=-  (no cocotb result: lint or compile-only variant)"

    local verdict=PASS
    if [ "$rc" -ne 0 ] || grep -qa 'FAIL=[1-9]' <<< "$c"; then verdict=FAIL; fi
    printf '%-4s %-4s rc=%-3s %s\n' "$a" "$verdict" "$rc" "$c" > "$LOGDIR/$a.counts"
}

{
  echo "run_relink_variants.sh  $(date -Is)   NIA_JOBS=$JOBS   variants: $VARIANTS"
  echo "  RTL md5 dcmac_ctl_seq.sv        $(md5sum "$HERE/../dcmac_ctl_seq.sv"         2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_link_wdt.sv     $(md5sum "$HERE/../dcmac_link_wdt.sv"      2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_axil_exec.sv    $(md5sum "$HERE/../dcmac_axil_exec.sv"     2>/dev/null | cut -d' ' -f1)"
  echo "  RTL md5 dcmac_link_csr.sv   $(md5sum "$HERE/../../dcmac_link_csr.sv" 2>/dev/null | cut -d' ' -f1)"
  echo "  verilator $(verilator --version 2>&1 | head -1)   cocotb $(python3 -c 'import cocotb;print(cocotb.__version__)' 2>/dev/null)"
} | tee "$SUMMARY"

for a in $VARIANTS; do
    if [ -z "${ARM[$a]:-}" ]; then echo "$a UNKNOWN_VARIANT" | tee -a "$SUMMARY"; continue; fi
    rm -f "$LOGDIR/$a.counts"
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 2; done
    run_arm "$a" &
done
wait

NPASS=0; NFAIL=0
for a in $VARIANTS; do
    if [ -f "$LOGDIR/$a.counts" ]; then
        cat "$LOGDIR/$a.counts" | tee -a "$SUMMARY"
        grep -q ' PASS ' "$LOGDIR/$a.counts" && NPASS=$((NPASS+1)) || NFAIL=$((NFAIL+1))
    else
        echo "$a NO_RESULT" | tee -a "$SUMMARY"; NFAIL=$((NFAIL+1))
    fi
done
echo "NIA_VARIANTS_DONE arms_pass=$NPASS arms_fail=$NFAIL" | tee -a "$SUMMARY"
[ "$NFAIL" -eq 0 ]
