#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : run_gates.sh
# Description : Runs every structural check that needs no simulator and no vendor tool,
#               and reports which passed, which failed, and which were not run and why.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

pass=0
fail=0
declare -a failed=()

run_gate() {
	local script="$1"
	shift
	local name
	name="$(basename "$script")"
	printf '== %s\n' "$name"
	if python3 "$script" "$@" > "/tmp/nia_gate_$$.out" 2>&1; then
		tail -3 "/tmp/nia_gate_$$.out" | sed 's/^/   /'
		printf '   PASS %s\n' "$name"
		pass=$((pass + 1))
	else
		tail -6 "/tmp/nia_gate_$$.out" | sed 's/^/   /'
		printf '   FAIL %s\n' "$name"
		fail=$((fail + 1))
		failed+=("$name")
	fi
	rm -f "/tmp/nia_gate_$$.out"
}

for g in \
	sim/gate/gate_datapath_owns_no_reset.py \
	sim/gate/gate_elaborate_sets.py \
	sim/gate/gate_reset_ownership.py \
	sim/gate/gate_reset_defaults.py \
	sim/gate/gate_ctl_seq_groups.py \
	sim/gate/gate_ctl_seq_waits.py \
	sim/gate/gate_param_overrides.py \
	sim/gate/gate_seg_sum_saturation.py \
	sim/gate/gate_image_source_selection.py \
	sim/gate/gate_stream_rate.py \
	sim/gate/gate_tcl_syntax.py \
	sim/gate/gate_tcl_var_kind.py \
	sim/gate/gate_flow_defaults.py \
	sim/gate/gate_port_width_params.py \
	sim/gate/gate_instrument_elab.py \
	sim/gate/gate_done_mask_matches_phy.py \
	sim/gate/preflight_anchors.py
do
	if [ -f "$g" ]; then
		case "$g" in
		*gate_datapath_owns_no_reset.py) run_gate "$g" rtl ;;
		*gate_elaborate_sets.py) run_gate "$g" . ;;
		*gate_ctl_seq_groups.py|*gate_ctl_seq_waits.py|*preflight_anchors.py) run_gate "$g" ;;
		*gate_image_source_selection.py) run_gate "$g" ;;
		*gate_port_width_params.py) run_gate "$g" "$ROOT" ;;
		*gate_flow_defaults.py) run_gate "$g" "$ROOT" ;;
		*gate_done_mask_matches_phy.py) run_gate "$g" "$ROOT" ;;
		*gate_tcl_var_kind.py) run_gate "$g" "$ROOT" ;;
		*gate_tcl_syntax.py) run_gate "$g" "$ROOT" ;;
		*gate_stream_rate.py) run_gate "$g" ;;
		*gate_instrument_elab.py) run_gate "$g" ;;
		*gate_seg_sum_saturation.py) run_gate "$g" ;;
		*) run_gate "$g" "$ROOT" ;;
		esac
	else
		printf '== %s\n   FAIL absent\n' "$g"
		fail=$((fail + 1))
		failed+=("$(basename "$g") absent")
	fi
done

printf '\n== not run here, and why\n'
for g in sim/gate/gate_polarity.py sim/gate/gate_serdes_reset_isolation.py \
	sim/gate/gate_quad_readiness.py sim/gate/gate_dual_port_reset_sync.py
do
	[ -f "$g" ] && printf '   %s: takes a subject outside this repository or a copy to mutate\n' "$(basename "$g")"
done
printf '   the mutation runners under sim/seam and sim/ctl_seq: sim/nia_rtl_lock.py resolves no reference tree in a standalone checkout\n'

printf '\nGATES: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
	printf 'failing: %s\n' "${failed[*]}"
	exit 1
fi
exit 0
