#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_elab_both.sh
# Description : Elaborates the single group and the two group sequencer sets, so a change
#               is known to build in both before either is run.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCMAC="$HERE/../.."
PV="$DCMAC/../.."

V="${VERILATOR:-verilator}"
echo "run_elab_both.sh  $(date -Is)"
echo "  $($V --version 2>&1 | head -1)"
case "$($V --version 2>&1)" in
  *4.0*) echo "   REFUSING: this is verilator 4.x. It accepts -G widths that 5.x rejects, so a pass"
         echo "     here would prove nothing. export PATH=\$HOME/local/bin:\$PATH"; exit 2 ;;
esac
echo

WAIVE=(
  -Wno-DECLFILENAME
  -Wno-VARHIDDEN
  -Wno-UNUSED
  -Wno-UNUSEDSIGNAL
  -Wno-UNUSEDPARAM
  -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -Wno-TIMESCALEMOD
  -Wno-PINCONNECTEMPTY
  -Wno-SYNCASYNCNET
  -Wno-MULTIDRIVEN
  -Wno-CASEINCOMPLETE
  -Wno-UNOPTFLAT
  -Wno-BLKANDNBLK
  -Wno-MODDUP
  -Wno-CMPCONST
)

FAIL=0
SKIP=0
elab () {
  local name="$1"; shift
  printf '%-34s ' "$name"
  local out
  out="$("$@" 2>&1)"
  local n
  n="$(grep -cE '^%(Error|Warning)' <<< "$out")"
  if [ "$n" -eq 0 ]; then
    echo "issues=0  PASS"
  else
    echo "issues=$n  FAIL"
    grep -E '^%(Error|Warning)' <<< "$out" | head -8 | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

cd "$DCMAC" || exit 3
SRC=(ctl/dcmac_ctl_pkg.sv)
while IFS= read -r f; do SRC+=("$f"); done < <(ls ./*.sv | grep -v phy_dcmac)
while IFS= read -r f; do SRC+=("$f"); done < <(ls ctl/*.sv)
while IFS= read -r f; do SRC+=("$f"); done < <(ls fifo_model/*.sv)

for T in dcmac_mac_group dcmac_axis_top dcmac_port \
         dcmac_link_ctl dcmac_link_sample wdt dcmac_mac_ctl_fsm dcmac_ctl_seq \
         dcmac_axil_exec dcmac_link_csr; do
  elab "rtl/$T" "$V" --lint-only -Wall "${WAIVE[@]}" --top-module "$T" "${SRC[@]}"
done

VARIANTSRC=("${SRC[@]}")
for d in "$DCMAC/../cndm_mac" "$DCMAC/../mqnic_mac"; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do VARIANTSRC+=("$f"); done < <(ls "$d"/*.sv "$d"/*.v 2>/dev/null)
done
for T in nia_cndm_dcmac_dualmac; do
  grep -rqE "^\s*module\s+$T\b" "$DCMAC/../cndm_mac" 2>/dev/null || continue
  elab "wrap/$T" "$V" --lint-only -Wall "${WAIVE[@]}" --top-module "$T" "${VARIANTSRC[@]}"
done

for T in nia_cndm_dcmac_shim nia_cndm_dcmac_client; do
  printf '%-34s %s\n' "wrap/$T" "SKIP (needs taxi_axis_if from the vendored taxi tree)"
  SKIP=$((SKIP+1))
done

echo
printf '%-34s ' "scan/retired-parameters"
RET=$(grep -rlnE '\.(ESC_MAX_STAGE|T_RXDP_MS_ESC|RX_RESET_CYCLES)\(' "$DCMAC/.." \
        --include=*.sv --include=*.v 2>/dev/null | grep -vE '/(sim|sim_ip|lint|tb)/' || true)
if [ -z "$RET" ]; then echo "none in synthesisable RTL  PASS"
else echo "FAIL"; echo "$RET" | sed 's/^/      /'; FAIL=$((FAIL+1)); fi

echo
printf '%-34s ' "scan/parameter-overrides"
if python3 "$HERE/gate_param_overrides.py" "$DCMAC/.."; then :; else FAIL=$((FAIL+1)); fi

echo
MQ="$PV/example/TU03_nic/mqnic_mac/dual/rtl/fpga.v"
TX="$PV/example/TU03_nic/taxi_dcmac/rtl/fpga_dp.sv"
for f in "$MQ" "$TX"; do
  if [ -f "$f" ]; then
    printf '%-34s ' "top/$(basename "$f")"
    bad=$(grep -cE '\.(ESC_MAX_STAGE|T_RXDP_MS_ESC|RX_RESET_CYCLES)\(' "$f")
    if [ "$bad" -eq 0 ]; then echo "no retired parameter  PASS"
    else echo "$bad retired parameter(s) still emitted  FAIL"
         grep -nE '\.(ESC_MAX_STAGE|T_RXDP_MS_ESC|RX_RESET_CYCLES)\(' "$f" | head -4 | sed 's/^/      /'
         FAIL=$((FAIL+1)); fi
  elif [ -d "$PV/example" ]; then
    printf '%-34s %s\n' "top/$(basename "$f")" "MISSING - regenerate it"; FAIL=$((FAIL+1))
  else
    printf '%-34s %s\n' "top/$(basename "$f")" "SKIP (no example/ in this tree - sync app/pcie_versal)"
    SKIP=$((SKIP+1))
  fi
done

echo
for g in "$PV/example/TU03_nic/mqnic_mac/gen/gen_mqnic_dual_board.py" \
         "$PV/example/TU03_nic/taxi_dcmac/gen/gen_taxi_dcmac_dp_top.py" \
         "$PV/gen/gen_mqnic_full_wrap.py"; do
  printf '%-34s ' "gen/$(basename "$g")"
  if [ ! -f "$g" ]; then
    echo "SKIP (not in this tree - sync app/pcie_versal)"; SKIP=$((SKIP+1)); continue
  fi
  if out="$(cd "$(dirname "$g")" && python3 "$(basename "$g")" 2>&1)"; then
    tail=$(grep -aoE '(SELF-CHECK TOTAL [0-9]+ BAD [0-9]+|SELFCHECK [0-9]+/[0-9]+|RESULT: PASS|NIA_F1_OK.*)' <<< "$out" | tail -1)
    if grep -qE 'BAD [1-9]|FAIL' <<< "$out"; then echo "FAIL  ${tail:-see output}"; FAIL=$((FAIL+1))
    else echo "PASS  ${tail:-ok}"; fi
  else
    echo "FAIL  generator exited non-zero"; FAIL=$((FAIL+1))
  fi
done

echo
echo "NIA_ELAB_DONE fail=$FAIL skip=$SKIP"
exit $(( FAIL > 0 ? 1 : 0 ))
