#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_seg_ring.sh
# Description : The receive segment ring at every segment count the DCMAC offers, under
#               both simulators, in a lossless arm and a starved arm.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work="$here/sim_build_seg_ring"
rtl="$root/rtl/dcmac_seg_axis_adapter.sv"
tb="$root/sim/tb/tb_dcmac_seg_axis_rx.sv"
top=tb_dcmac_seg_axis_rx

rm -rf "$work"
mkdir -p "$work"
cd "$work" || exit 2

pass=0
fail=0

run_icarus() {
	local n="$1" gaps="$2" loss="$3" name="$4" out
	iverilog -g2012 -o "$name.vvp" \
		-P${top}.N_SEG="$n" -P${top}.READY_GAPS="$gaps" -P${top}.EXPECT_LOSS="$loss" \
		-s "$top" "$rtl" "$tb" >"$name.build" 2>&1
	if [ $? -ne 0 ]; then
		echo "  icarus $name BUILD FAILED"
		sed -n '1,6p' "$name.build"
		fail=$((fail + 1))
		return
	fi
	out=$(vvp "$name.vvp" 2>&1 | grep -E "^(PASS|FAIL)" ; true)
	if echo "$out" | grep -q "^PASS"; then
		echo "  icarus $name $(echo "$out" | grep '^PASS')"
		pass=$((pass + 1))
	else
		echo "  icarus $name FAILED"
		echo "$out" | sed 's|^|    |'
		fail=$((fail + 1))
	fi
}

run_verilator() {
	local n="$1" gaps="$2" loss="$3" name="$4" out
	verilator --binary -Wno-fatal --timing -j 4 \
		-GN_SEG="$n" -GREADY_GAPS="$gaps" -GEXPECT_LOSS="$loss" \
		--top-module "$top" -Mdir "obj_$name" -o "$name" \
		"$rtl" "$tb" >"$name.vbuild" 2>&1
	if [ $? -ne 0 ]; then
		echo "  verilator $name BUILD FAILED"
		grep -E "%Error" "$name.vbuild" | sed -n '1,6p'
		fail=$((fail + 1))
		return
	fi
	out=$("obj_$name/$name" 2>&1 | grep -E "^(PASS|FAIL)" ; true)
	if echo "$out" | grep -q "^PASS"; then
		echo "  verilator $name $(echo "$out" | grep '^PASS')"
		pass=$((pass + 1))
	else
		echo "  verilator $name FAILED"
		echo "$out" | sed 's|^|    |'
		fail=$((fail + 1))
	fi
}

for n in 2 4 8; do
	echo "N_SEG=$n"
	run_icarus    "$n" 0 0 "lossless_n$n"
	run_icarus    "$n" 1 1 "starved_n$n"
	run_verilator "$n" 0 0 "lossless_n$n"
	run_verilator "$n" 1 1 "starved_n$n"
done

echo
if [ "$fail" -eq 0 ]; then
	echo "SEG RING RESULT PASS ($pass arms)"
	exit 0
fi
echo "SEG RING RESULT FAIL ($fail of $((pass + fail)) arms)"
exit 1
