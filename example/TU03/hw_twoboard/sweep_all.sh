#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : sweep_all.sh
# Description : Runs sweep_twoboard.sh over every device image found, one after
#               another, and prints one row per image. Each image is swept with
#               the cage count and frame length range of its own manifest, so a
#               400G image is swept as one cage and a dual image as two.
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
OUT="${OUT:-$HOME/nia_sweep}"
LOG="$OUT/sweep_all.log"

usage() {
	cat <<EOF
sweep_all.sh [image_dir]

  Sweeps every <top>.pdi in the image directory that carries a
  <top>.image_props.txt manifest beside it. The manifest is written by
  build_image.tcl and names the generator, the rate, the cage count, the
  datapath frequency and the frame length range of that image.

  NIA_IMAGE_DIR  directory holding the device images, default build/image
  SERIAL_A       JTAG cable serial of board A, required
  SERIAL_B       JTAG cable serial of board B, required
  OUT            output directory, default \$HOME/nia_sweep

  Every variable that sweep_twoboard.sh honours is passed through, and a value
  set in the environment overrides the manifest for every image.
EOF
}

case "${1:-}" in
-h|--help) usage; exit 0 ;;
esac
[ $# -ge 1 ] && IMAGE_DIR="$1"

if [ -z "${SERIAL_A:-}" ] || [ -z "${SERIAL_B:-}" ]; then
	echo "sweep_all: set SERIAL_A and SERIAL_B to the JTAG cable serials of the two boards."
	echo "           program_twoboard.sh list prints every target so the serials can be read."
	exit 2
fi

[ -d "$IMAGE_DIR" ] || { echo "sweep_all: $IMAGE_DIR is not a directory"; exit 2; }

mkdir -p "$OUT"
: > "$LOG"

images=()
while IFS= read -r p; do images+=("$p"); done < <(find "$IMAGE_DIR" -name '*.pdi' | sort)
[ "${#images[@]}" -gt 0 ] || { echo "sweep_all: $IMAGE_DIR holds no .pdi"; exit 2; }

echo "SWEEPALL IMAGES ${#images[@]} in $IMAGE_DIR" | tee -a "$LOG"

rows=""
fail=0
for pdi in "${images[@]}"; do
	props="${pdi%.pdi}.image_props.txt"
	label="$(basename "$pdi" .pdi)"
	pktgen="unknown"; rate="unknown"; clients="unknown"; mhz="unknown"
	if [ -f "$props" ]; then
		pktgen="$(sed -n 's/^NIA_PKTGEN=//p' "$props" | head -1)"
		rate="$(sed -n 's/^NIA_RATE=//p' "$props" | head -1)"
		clients="$(sed -n 's/^NIA_CLIENTS=//p' "$props" | head -1)"
		mhz="$(sed -n 's/^NIA_USR_MHZ=//p' "$props" | head -1)"
		label="${pktgen}${rate}g_${mhz}m"
	else
		echo "SWEEPALL SKIP $label: no manifest beside it, so its cage count is unknown" \
			| tee -a "$LOG"
		rows="$rows$label|no manifest|SKIP\n"
		continue
	fi

	echo "SWEEPALL RUN $label pktgen=$pktgen rate=$rate clients=$clients mhz=$mhz" \
		| tee -a "$LOG"
	OUT="$OUT/$label" NIA_LINE_GBPS="$rate" bash "$HERE/sweep_twoboard.sh" "$pdi" "$label" >>"$LOG" 2>&1
	rc=$?
	verdict="$(sed -n 's/^SWEEP RESULT *//p' "$LOG" | tail -1)"
	[ -n "$verdict" ] || verdict="no result line, sweep status $rc"
	case "$verdict" in
	PASS*) : ;;
	*) fail=$((fail + 1)) ;;
	esac
	rows="$rows$label|pktgen=$pktgen rate=$rate clients=$clients mhz=$mhz|$verdict\n"
done

echo | tee -a "$LOG"
echo "SWEEPALL TABLE" | tee -a "$LOG"
printf "%-18s %-46s %s\n" "IMAGE" "CONFIGURATION" "RESULT" | tee -a "$LOG"
printf '%b' "$rows" | while IFS='|' read -r a b c; do
	[ -n "$a" ] || continue
	printf "%-18s %-46s %s\n" "$a" "$b" "$c" | tee -a "$LOG"
done

echo | tee -a "$LOG"
if [ "$fail" -eq 0 ]; then
	echo "SWEEPALL RESULT PASS ${#images[@]} image(s)" | tee -a "$LOG"
else
	echo "SWEEPALL RESULT FAIL $fail of ${#images[@]} image(s)" | tee -a "$LOG"
fi
echo "SWEEPALL LOG $LOG" | tee -a "$LOG"
exit "$fail"
