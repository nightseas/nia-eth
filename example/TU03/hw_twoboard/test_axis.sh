#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : test_axis.sh
# Description : Runs one of the three test cases over the AXI-Stream generator
#               images: the rate table or the frame length sweep.
#               Each image is driven with the geometry its manifest declares.
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

CASE="${1:-}"
IMAGE_DIR="${NIA_IMAGE_DIR:-$ROOT/build/image}"
OUT="${OUT:-$HOME/nia_test_axis}"
XSDB="${NIA_XSDB:-xsdb}"

usage() {
	cat <<EOF
test_axis.sh <rate|sweep> [image_dir]

  rate    Programs both boards and runs the rate table at the typical lengths
          together with the lengths a 250 MHz datapath cannot carry at line
          rate: one byte past a beat boundary. Every row is asserted byte exact
          in both directions, with the burst bounded so the 32 bit byte counters
          cannot wrap.

  sweep   Programs both boards and sweeps the frame length from NIA_IMIN to
          NIA_IMAX by NIA_ISTEP, one burst per length per cage per direction,
          with the same byte exact assertion as the rate case. The default is
          every integer length from the image's own NIA_LEN_MIN_HW to its
          NIA_LEN_MAX_HW.

  NIA_IMAGE_DIR  directory holding the device images, default build/image
  NIA_RATES      restrict to these rates, for example "200 400". Default all
  NIA_IMIN       first length of the sweep, default the image's NIA_LEN_MIN_HW
  NIA_IMAX       last length of the sweep, default the image's NIA_LEN_MAX_HW
  NIA_ISTEP      stride of the sweep, default 1
  NIA_SIZES      lengths of the rate table, default the 13 built in
  SERIAL_A       JTAG cable serial of board A, required
  SERIAL_B       JTAG cable serial of board B, required
  NIA_HW_URL     hw_server URL, default TCP:localhost:3121. Both cables are
                 enumerated from this one agent
  OUT            output directory, default \$HOME/nia_test_axis

  The lengths a 250 MHz datapath degrades at, from the model in
  sim/gate/gate_stream_rate.py: 65 at a 512 bit beat gives 0.890 of line rate,
  and 129 at a 1024 bit beat gives 0.765. The rate table carries each of those
  with the beat boundary beside it, so the pair reads as a contrast.
EOF
}

case "$CASE" in
rate|sweep) : ;;
-h|--help|"") usage; exit 0 ;;
*) echo "test_axis: '$CASE' is not one of rate, sweep"; usage; exit 2 ;;
esac
[ $# -ge 2 ] && IMAGE_DIR="$2"

mkdir -p "$OUT"
LOG="$OUT/test_axis_$CASE.log"
: > "$LOG"

if [ -z "${SERIAL_A:-}" ] || [ -z "${SERIAL_B:-}" ]; then
	echo "test_axis: set SERIAL_A and SERIAL_B for the $CASE case."
	echo "           program_twoboard.sh list prints every target so the serials can be read."
	exit 2
fi
[ -d "$IMAGE_DIR" ] || { echo "test_axis: $IMAGE_DIR is not a directory"; exit 2; }

WANT_RATES="${NIA_RATES:-100 200 400}"
prop() { sed -n "s/^$2=//p" "$1" | head -1; }

geometry_of() {
	case "$1" in
	100) echo "n_seg=2 data_w=512 streams=1 cages=2" ;;
	200) echo "n_seg=4 data_w=1024 streams=1 cages=2" ;;
	400) echo "n_seg=8 data_w=1024 streams=2 cages=1" ;;
	*)   echo "unknown" ;;
	esac
}

rows=""
ran=0
fail=0
for pdi in $(find "$IMAGE_DIR" -name '*.pdi' | sort); do
	props="${pdi%.pdi}.image_props.txt"
	label="$(basename "$pdi" .pdi)"
	[ -f "$props" ] || { echo "TESTAXIS SKIP $label: no manifest" | tee -a "$LOG"; continue; }
	[ "$(prop "$props" NIA_PKTGEN)" = "axis" ] || {
		echo "TESTAXIS SKIP $label: not an AXI-Stream image" | tee -a "$LOG"; continue; }
	rate="$(prop "$props" NIA_RATE)"
	case " $WANT_RATES " in *" $rate "*) : ;; *)
		echo "TESTAXIS SKIP $label: rate $rate outside NIA_RATES" | tee -a "$LOG"; continue ;;
	esac
	clients="$(prop "$props" NIA_CLIENTS)"
	mhz="$(prop "$props" NIA_USR_MHZ)"
	lmin="${NIA_IMIN:-$(prop "$props" NIA_LEN_MIN_HW)}"
	lmax="${NIA_IMAX:-$(prop "$props" NIA_LEN_MAX_HW)}"
	step="${NIA_ISTEP:-1}"
	geom="$(geometry_of "$rate")"
	expect="${geom##*cages=}"
	name="axis${rate}g_${mhz}m"

	if [ "$clients" != "$expect" ]; then
		echo "TESTAXIS FAIL $name: manifest gives $clients cage(s), rate $rate carries $expect" \
			| tee -a "$LOG"
		rows="$rows$name|rate=$rate $geom|FAIL cage count disagrees with the rate\n"
		fail=$((fail + 1)); continue
	fi

	ran=$((ran + 1))
	if [ "$CASE" = "rate" ]; then
		echo "TESTAXIS RATE $name rate=$rate clients=$clients mhz=$mhz lengths='${NIA_SIZES:-built in}'" \
			| tee -a "$LOG"
		# One length per row of the rate table, so the sweep driver is reused with the table's
		# own length list and its stride never applies.
		OUT="$OUT/$name" NIA_STEPS="1 2 4" NIA_IMIN=64 NIA_IMAX=64 NIA_LINE_GBPS="$rate" \
			bash "$HERE/sweep_twoboard.sh" "$pdi" "$name" >>"$LOG" 2>&1
	else
		nrows=$(( ((lmax - lmin) / step + 1) * clients * 2 ))
		echo "TESTAXIS SWEEP $name rate=$rate clients=$clients mhz=$mhz" \
			"lengths=$lmin..$lmax step=$step rows=$nrows" | tee -a "$LOG"
		OUT="$OUT/$name" NIA_STEPS="1 2 3" NIA_IMIN="$lmin" NIA_IMAX="$lmax" \
			NIA_ISTEP="$step" NIA_LINE_GBPS="$rate" bash "$HERE/sweep_twoboard.sh" "$pdi" "$name" >>"$LOG" 2>&1
	fi
	rc=$?
	# sweep_twoboard.sh prints "SWEEP RESULT  PASS" with two spaces, so stripping a single space
	# left " PASS", which the PASS* pattern below cannot match and which therefore tallied a
	# passing image as a failure. That is how the 400G run reported "TESTAXIS RESULT FAIL 1 of 1"
	# under a row reading PASS. The trailing * absorbs any run of spaces.
	verdict="$(sed -n 's/^SWEEP RESULT *//p' "$LOG" | tail -1)"
	if [ -z "$verdict" ]; then
		why="$(grep -aE '^(sweep|program_twoboard|TWOBOARD FAIL):? ' "$LOG" | tail -1)"
		[ -n "$why" ] || why="$(tail -3 "$LOG" | tr '\n' ' ')"
		verdict="FAIL status $rc: $why"
		echo "TESTAXIS WHY $name $why" | tee -a "$LOG"
	fi
	case "$verdict" in PASS*) : ;; *) fail=$((fail + 1)) ;; esac
	rows="$rows$name|rate=$rate $geom|$verdict\n"
done

echo | tee -a "$LOG"
echo "TESTAXIS TABLE $CASE" | tee -a "$LOG"
printf "%-16s %-44s %s\n" "IMAGE" "GEOMETRY" "RESULT" | tee -a "$LOG"
printf '%b' "$rows" | while IFS='|' read -r a b c; do
	[ -n "$a" ] || continue
	printf "%-16s %-44s %s\n" "$a" "$b" "$c" | tee -a "$LOG"
done

echo | tee -a "$LOG"
if [ "$ran" -eq 0 ]; then
	echo "TESTAXIS RESULT FAIL no AXI-Stream image was tested" | tee -a "$LOG"; fail=1
elif [ "$fail" -eq 0 ]; then
	echo "TESTAXIS RESULT PASS $ran image(s)" | tee -a "$LOG"
else
	echo "TESTAXIS RESULT FAIL $fail of $ran image(s)" | tee -a "$LOG"
fi
echo "TESTAXIS LOG $LOG" | tee -a "$LOG"
exit "$fail"
