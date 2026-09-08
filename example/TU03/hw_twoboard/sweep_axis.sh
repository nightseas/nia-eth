#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : sweep_axis.sh
# Description : Runs the two board frame length sweep over the AXI-Stream
#               generator images, one rate at a time, and checks each image
#               against the geometry its manifest declares.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

IMAGE_DIR="${NIA_IMAGE_DIR:-$ROOT/build/image}"
OUT="${OUT:-$HOME/nia_sweep_axis}"
LOG="$OUT/sweep_axis.log"

usage() {
	cat <<EOF
sweep_axis.sh [image_dir]

  Sweeps every AXI-Stream generator image in the directory. An image is taken as
  AXI-Stream when its <top>.image_props.txt manifest carries NIA_PKTGEN=axis.

  For each image the script states the geometry the manifest declares, runs
  sweep_twoboard.sh with the cage count and frame length range of that manifest,
  and reports the sweep result.

  The stream count per cage is derived from the rate rather than read from the
  manifest, because the three images built before this script carry no such
  field: rate 400 uses two streams on one cage, and 100 and 200 use one stream
  on each of two cages.

  NIA_IMAGE_DIR  directory holding the device images, default build/image
  SERIAL_A       JTAG cable serial of board A, required
  SERIAL_B       JTAG cable serial of board B, required
  OUT            output directory, default \$HOME/nia_sweep_axis
  NIA_RATES      restrict to these rates, for example "200 400". Default all
  NIA_IDENSE     last length of the dense band. This script defaults it to the
                 NIA_LEN_MAX_HW of each image, so every integer length from 64
                 to 9018 is covered and the stride of sweep_twoboard.sh never
                 applies. That is 8955 lengths, and the row count per image is
                 printed before the sweep starts

  Every variable sweep_twoboard.sh honours is passed through, and a value set in
  the environment overrides the manifest for every image.
EOF
}

case "${1:-}" in
-h|--help) usage; exit 0 ;;
esac
[ $# -ge 1 ] && IMAGE_DIR="$1"

if [ -z "${SERIAL_A:-}" ] || [ -z "${SERIAL_B:-}" ]; then
	echo "sweep_axis: set SERIAL_A and SERIAL_B to the JTAG cable serials of the two boards."
	echo "            program_twoboard.sh list prints every target so the serials can be read."
	exit 2
fi
[ -d "$IMAGE_DIR" ] || { echo "sweep_axis: $IMAGE_DIR is not a directory"; exit 2; }

WANT_RATES="${NIA_RATES:-100 200 400}"

mkdir -p "$OUT"
: > "$LOG"

prop() { sed -n "s/^$2=//p" "$1" | head -1; }

# The geometry each rate presents, which the sweep checks the device against. N_SEG decides the
# line rate in pktgen_twoboard_lib.tcl as N_SEG x 50 Gbps.
geometry_of() {
	case "$1" in
	100) echo "n_seg=2 data_w=512 streams=1 cages=2" ;;
	200) echo "n_seg=4 data_w=1024 streams=1 cages=2" ;;
	400) echo "n_seg=8 data_w=1024 streams=2 cages=1" ;;
	*)   echo "unknown" ;;
	esac
}

images=()
while IFS= read -r p; do images+=("$p"); done < <(find "$IMAGE_DIR" -name '*.pdi' | sort)
[ "${#images[@]}" -gt 0 ] || { echo "sweep_axis: $IMAGE_DIR holds no .pdi"; exit 2; }

rows=""
ran=0
fail=0
for pdi in "${images[@]}"; do
	props="${pdi%.pdi}.image_props.txt"
	label="$(basename "$pdi" .pdi)"
	if [ ! -f "$props" ]; then
		echo "SWEEPAXIS SKIP $label: no manifest, so the generator is unknown" | tee -a "$LOG"
		continue
	fi
	pktgen="$(prop "$props" NIA_PKTGEN)"
	if [ "$pktgen" != "axis" ]; then
		echo "SWEEPAXIS SKIP $label: manifest says pktgen=$pktgen" | tee -a "$LOG"
		continue
	fi
	rate="$(prop "$props" NIA_RATE)"
	case " $WANT_RATES " in *" $rate "*) : ;; *)
		echo "SWEEPAXIS SKIP $label: rate $rate is outside NIA_RATES='$WANT_RATES'" | tee -a "$LOG"
		continue ;;
	esac

	clients="$(prop "$props" NIA_CLIENTS)"
	mhz="$(prop "$props" NIA_USR_MHZ)"
	lmin="$(prop "$props" NIA_LEN_MIN_HW)"
	lmax="$(prop "$props" NIA_LEN_MAX_HW)"
	geom="$(geometry_of "$rate")"
	expect_cages="${geom##*cages=}"
	name="axis${rate}g_${mhz}m"

	rows_n=$(( (lmax - lmin + 1) * clients * 2 ))
	echo "SWEEPAXIS RUN $name rate=$rate clients=$clients mhz=$mhz lengths=$lmin..$lmax $geom" \
		"rows=$rows_n" | tee -a "$LOG"
	if [ "$clients" != "$expect_cages" ]; then
		echo "SWEEPAXIS FAIL $name: the manifest gives $clients cage(s) and rate $rate carries" \
			"$expect_cages" | tee -a "$LOG"
		rows="$rows$name|rate=$rate $geom|FAIL cage count disagrees with the rate\n"
		fail=$((fail + 1))
		continue
	fi

	ran=$((ran + 1))
	OUT="$OUT/$name" NIA_IDENSE="${NIA_IDENSE:-$lmax}" \
		bash "$HERE/sweep_twoboard.sh" "$pdi" "$name" >>"$LOG" 2>&1
	rc=$?
	verdict="$(sed -n 's/^SWEEP RESULT *//p' "$LOG" | tail -1)"
	[ -n "$verdict" ] || verdict="no result line, sweep status $rc"
	# The device states its own geometry, and a disagreement with the manifest means the wrong
	# image is on the board.
	seen="$(sed -n 's/^TWOBOARD RATE //p' "$LOG" | tail -1)"
	[ -n "$seen" ] && echo "SWEEPAXIS DEVICE $name reports $seen" | tee -a "$LOG"
	case "$verdict" in
	PASS*) : ;;
	*) fail=$((fail + 1)) ;;
	esac
	rows="$rows$name|rate=$rate $geom|$verdict\n"
done

echo | tee -a "$LOG"
echo "SWEEPAXIS TABLE" | tee -a "$LOG"
printf "%-16s %-44s %s\n" "IMAGE" "GEOMETRY" "RESULT" | tee -a "$LOG"
printf '%b' "$rows" | while IFS='|' read -r a b c; do
	[ -n "$a" ] || continue
	printf "%-16s %-44s %s\n" "$a" "$b" "$c" | tee -a "$LOG"
done

echo | tee -a "$LOG"
if [ "$ran" -eq 0 ]; then
	echo "SWEEPAXIS RESULT FAIL no AXI-Stream image was swept" | tee -a "$LOG"
	fail=1
elif [ "$fail" -eq 0 ]; then
	echo "SWEEPAXIS RESULT PASS $ran image(s)" | tee -a "$LOG"
else
	echo "SWEEPAXIS RESULT FAIL $fail of $ran image(s)" | tee -a "$LOG"
fi
echo "SWEEPAXIS LOG $LOG" | tee -a "$LOG"
exit "$fail"
