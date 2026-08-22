#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_csr_tb.sh
# Description : Runs the control plane register block test bench under verilator or xsim,
#               outside cocotb.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../../rtl"
MODE="${1:-verilator}"
OUT="$HERE/obj_csr"
TOP=tb_dcmac_link_csr

SRC=("$RTL/dcmac_link_csr.sv" "$HERE/../tb/tb_dcmac_link_csr.sv")

echo "NIA_CSR_TB mode=$MODE"
md5sum "${SRC[@]}"

rm -rf "$OUT"
mkdir -p "$OUT"

case "$MODE" in
verilator)
    VER="$(verilator --version 2>/dev/null | awk '{print $2}')"
    echo "NIA_CSR_TB verilator=$VER"
    case "$VER" in
      4.*) echo "NIA_CSR_TB SKIP: verilator $VER has no --timing; use 5.x or 'xsim'"; exit 2 ;;
    esac
    verilator --binary --timing -j 0 -Wno-STMTDLY -Wno-WIDTH -Wno-DECLFILENAME \
              -Wno-VARHIDDEN -Wno-BLKSEQ -Wno-COMBDLY \
              --Mdir "$OUT" --top-module "$TOP" "${SRC[@]}" 2>&1 | tail -20
    "$OUT/V$TOP" 2>&1 | tee "$OUT/run.log"
    ;;
xsim)
    cd "$OUT" || exit 1
    xvlog -sv "${SRC[@]}"          2>&1 | tail -5
    xelab -debug typical "$TOP" -s tb_csr 2>&1 | tail -5
    xsim tb_csr -runall            2>&1 | tee run.log
    ;;
*)
    echo "usage: $0 [verilator|xsim]"; exit 1 ;;
esac

LOG="$OUT/run.log"
echo "--- verdict ---"
grep -E "^TEST |^TB_RESULT" "$LOG" || echo "NIA_CSR_TB NO_VERDICT (the run produced no TB_RESULT)"
if grep -q "^TB_RESULT PASS" "$LOG"; then echo "NIA_CSR_TB DONE PASS"; exit 0; fi
echo "NIA_CSR_TB DONE FAIL"; exit 1
