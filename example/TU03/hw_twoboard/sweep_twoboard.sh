#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# File        : sweep_twoboard.sh
# Description : Drives one image through the two board bench: programs both
#               boards, brings the links up, then sweeps every frame length from
#               NIA_IMIN to NIA_IMAX inclusive, one burst per length, comparing
#               each cage's transmit counts against the same cage on the far
#               board in both directions. Writes one log and one per length
#               verdict table per image.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${NIA_VIVADO_BIN:-}" ]; then
	BIN="$NIA_VIVADO_BIN"
elif command -v vivado >/dev/null 2>&1; then
	BIN=vivado
elif command -v vivado_lab >/dev/null 2>&1; then
	BIN=vivado_lab
else
	BIN=vivado
fi
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"
IMIN="${NIA_IMIN:-64}"
IMAX="${NIA_IMAX:-9018}"
ISTEP="${NIA_ISTEP:-1}"
EQ_BYTES="${NIA_EQ_BYTES:-15000000}"
BURST_MS="${NIA_BURST_MS:-60000}"
STEPS="${NIA_STEPS:-1 2 3}"
CLIENTS="${NIA_CLIENTS:-2}"
OUT="${OUT:-$HOME/nia_sweep}"

usage() {
	cat <<EOF
sweep_twoboard.sh <image.pdi> [label]

  NIA_CLIENTS   cages the image carries, 2 for a dual image and 1 for 400G. Default 2
  NIA_IMIN      first frame length, default 64
  NIA_IMAX      last frame length inclusive, default 9018, the LEN_MAX_HW of every image
  NIA_ISTEP     stride from NIA_IMIN to NIA_IMAX, default 1, so every integer length is
                covered. The defect this sweep exists to catch is a function of len mod 32,
                so a stride above 1 shall be coprime with 32 to visit every tail class: 97
                is the value the two band form used above 1518 and it remains a sound
                choice for a short run. NIA_IMAX is always included
  NIA_STEPS     which steps of the wire test run, default "1 2 3": link up, one warm-up
                burst discarded, and the length sweep. Add 4 for the rate table, or use
                "1 2 4" for the rate table alone. Steps 3 and 4 both assert byte equality
  NIA_SIZES     lengths of the rate table, used by step 4 only
  NIA_EQ_BYTES  bytes per length per cage, default 15000000. The wire test's own default
                is 3000000000, which over a full sweep is terabytes, so this lowers it to
                one short burst per length
  SERIAL_A      JTAG cable serial of board A, required
  SERIAL_B      JTAG cable serial of board B, required
  OUT           output directory, default \$HOME/nia_sweep

It programs, links, then sweeps. A length is EXACT only when the far board received
the same frame and byte counts with no error frame and no mismatched beat, and the
sweep covers both directions because every board is a generator at every length.
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
PDI="$1"
LABEL="${2:-$(basename "$PDI" .pdi)}"
[ -f "$PDI" ] || { echo "sweep: $PDI is not a file"; exit 2; }

# The build writes <top>.image_props.txt beside the device image. Reading it is what makes the
# cage count, the frame length range and the rate match the image being programmed: a 400G
# image carries one cage and the default of 2 would sweep a cage that does not exist.
PROPS="${PDI%.pdi}.image_props.txt"
PROP_RATE=""
PROP_PKTGEN=""
PROP_MHZ=""
if [ -f "$PROPS" ]; then
	while IFS='=' read -r k v; do
		case "$k" in
		NIA_CLIENTS)    [ -z "${NIA_CLIENTS:-}" ] && CLIENTS="$v" ;;
		NIA_LEN_MIN_HW) [ -z "${NIA_IMIN:-}" ]    && IMIN="$v" ;;
		NIA_LEN_MAX_HW) [ -z "${NIA_IMAX:-}" ]    && IMAX="$v" ;;
		NIA_RATE)       PROP_RATE="$v" ;;
		NIA_PKTGEN)     PROP_PKTGEN="$v" ;;
		NIA_USR_MHZ)    PROP_MHZ="$v" ;;
		esac
	done < "$PROPS"
	echo "sweep: $PROPS gives pktgen=$PROP_PKTGEN rate=$PROP_RATE clients=$CLIENTS" \
	     "usr_mhz=$PROP_MHZ lengths $IMIN..$IMAX"
else
	echo "sweep: no manifest beside $PDI, so clients=$CLIENTS and lengths $IMIN..$IMAX are" \
	     "the defaults and may not match the image"
fi

# The AXI-Stream geometry register publishes the stream width, and 1024 bits is both a 200G and
# a 400G client, so the library refuses to derive the rate and requires NIA_LINE_GBPS. The
# manifest carries it as NIA_RATE, so take it from there when the caller did not set it.
if [ -z "${NIA_LINE_GBPS:-}" ] && [ -n "$PROP_RATE" ]; then
	NIA_LINE_GBPS="$PROP_RATE"
	echo "sweep: NIA_LINE_GBPS=$NIA_LINE_GBPS taken from NIA_RATE of the manifest"
fi
if [ -z "$SERIAL_A" ] || [ -z "$SERIAL_B" ]; then
	echo "sweep: set SERIAL_A and SERIAL_B to the JTAG cable serials of the two boards."
	echo "       program_twoboard.sh list prints every target so the serials can be read."
	exit 2
fi
if [ "$SERIAL_A" = "$SERIAL_B" ]; then
	echo "sweep: SERIAL_A and SERIAL_B both name $SERIAL_A, so there is one board and no wire."
	exit 2
fi

command -v "$BIN" >/dev/null || { echo "sweep: '$BIN' is not on the path, source settings64.sh"; exit 2; }

RUN="$OUT/${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"
LOG="$RUN/sweep.log"

sizes=""
for ((i = IMIN; i <= IMAX; i += ISTEP)); do sizes="$sizes $i"; done
case " $sizes " in *" $IMAX "*) ;; *) sizes="$sizes $IMAX" ;; esac
n_sizes=$(printf '%s\n' $sizes | wc -l)

{
	echo "SWEEP IMAGE   $LABEL"
	echo "SWEEP PDI     $PDI"
	echo "SWEEP MD5     $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "SWEEP BOARDS  A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS"
	echo "SWEEP LENGTHS $IMIN to $IMAX inclusive, $n_sizes lengths, $EQ_BYTES bytes each"
	echo "SWEEP LENGTHS $IMIN to $IMAX step $ISTEP, $n_sizes length(s)"
	echo "SWEEP TOOL    $("$BIN" -version 2>/dev/null | head -1)"
	echo "SWEEP START   $(date -Is)"
} | tee "$LOG"

echo "== programming both boards" | tee -a "$LOG"
SERIAL_A="$SERIAL_A" SERIAL_B="$SERIAL_B" NIA_VIVADO_BIN="$BIN" \
	"$HERE/program_twoboard.sh" program "$PDI" "$PDI" 2>&1 | tee -a "$LOG"
prog_rc=${PIPESTATUS[0]}
if [ "$prog_rc" != 0 ]; then
	echo "SWEEP RESULT FAIL programming returned $prog_rc" | tee -a "$LOG"
	exit 1
fi

echo "== resolving DPC target ids from the cable serials" | tee -a "$LOG"
XSDB="${NIA_XSDB:-xsdb}"
command -v "$XSDB" >/dev/null || { echo "sweep: '$XSDB' is not on the path" | tee -a "$LOG"; exit 2; }
"$XSDB" "$HERE/dpc_ids.tcl" 2>&1 | tee -a "$LOG" | grep "^DPCID " > "$RUN/dpc.txt"
DPC_A="$(awk -v s="$SERIAL_A" '$2 == s {print $3}' "$RUN/dpc.txt" | head -1)"
DPC_B="$(awk -v s="$SERIAL_B" '$2 == s {print $3}' "$RUN/dpc.txt" | head -1)"
if [ -z "$DPC_A" ] || [ -z "$DPC_B" ]; then
	echo "SWEEP RESULT FAIL no DPC target id for serial $SERIAL_A or $SERIAL_B" | tee -a "$LOG"
	cat "$RUN/dpc.txt" | tee -a "$LOG"
	exit 1
fi
echo "  board A serial $SERIAL_A is DPC target $DPC_A" | tee -a "$LOG"
echo "  board B serial $SERIAL_B is DPC target $DPC_B" | tee -a "$LOG"

# A conditional assignment prefix of the form ${VAR:+NAME="$VAR"} is not an assignment to the
# parser, because the word does not begin with a name. It therefore ends the assignment prefix
# list, every following NAME=value becomes an argument, and the first of those becomes the command
# name. That is why the wire step reported 'NIA_STEPS=1 2 4: command not found' and never ran.
# Exporting inside a subshell keeps the conditional behaviour without the parsing hazard.
run_xsdb() {
	script="$1"
	shift
	(
		export NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS"
		[ -n "${NIA_LINE_GBPS:-}" ] && export NIA_LINE_GBPS
		[ -n "${NIA_SIZES:-}" ] && export NIA_SIZES
		while [ $# -gt 0 ]; do export "$1"; shift; done
		"$XSDB" "$script" 2>&1
	)
}

echo "== bringing the links up" | tee -a "$LOG"
run_xsdb "$HERE/pktgen_twoboard_link.tcl" | tee -a "$LOG"

# The link script prints 'STEP <n> RESULT PASS' and 'TWOBOARD LINK RESULT PASS'. The earlier
# patterns matched neither, so a healthy link was reported as having produced no pass token.
if ! grep -qE "STEP [0-9]+ RESULT PASS|TWOBOARD LINK RESULT PASS" "$LOG"; then
	echo "== link step reported no pass token, continuing so the traffic decides" | tee -a "$LOG"
fi

echo "== reading the MAC and FEC statistics before traffic" | tee -a "$LOG"
run_xsdb "$HERE/pktgen_twoboard_stats.tcl" > "$RUN/stats_before.log" 2>&1 || true
grep -E 'FEC_(CW|CORR|UNCORR)|SRX_|STX_|RX_MAC_RT|nonzero' "$RUN/stats_before.log" \
	| sed 's/^/BEFORE /' | tee -a "$LOG"

echo "== sweeping $n_sizes lengths, both directions" | tee -a "$LOG"
run_xsdb "$HERE/pktgen_twoboard_wire.tcl" \
	"NIA_STEPS=$STEPS" "NIA_EQ_SIZES=$sizes" "NIA_EQ_BYTES=$EQ_BYTES" \
	"NIA_BURST_MS=$BURST_MS" | tee -a "$LOG"

echo "== reading the MAC and FEC statistics after traffic" | tee -a "$LOG"
run_xsdb "$HERE/pktgen_twoboard_stats.tcl" > "$RUN/stats_after.log" 2>&1 || true
grep -E 'FEC_(CW|CORR|UNCORR)|SRX_|STX_|RX_MAC_RT|nonzero' "$RUN/stats_after.log" \
	| sed 's/^/AFTER /' | tee -a "$LOG"

grep -E "^STEP 3 len" "$LOG" > "$RUN/per_length.txt" 2>/dev/null

total=$(grep -c "^STEP 3 len" "$RUN/per_length.txt" 2>/dev/null || true)
exact=$(grep -c "EXACT" "$RUN/per_length.txt" 2>/dev/null || true)
bad=$(grep -c "MISMATCH" "$RUN/per_length.txt" 2>/dev/null || true)
tmo=$(grep -c "^STEP 3 len .* TIMEOUT" "$LOG" 2>/dev/null || true)
lengths=$(awk '{print $4}' "$RUN/per_length.txt" 2>/dev/null | sort -un | wc -l)
total=${total:-0}; exact=${exact:-0}; bad=${bad:-0}; tmo=${tmo:-0}

# The per length rows come from step 3. When the caller asked for a step list without it, as the
# rate case of test_axis.sh does with NIA_STEPS="1 2 4", there are no rows to count and the
# coverage test cannot decide anything. The result then comes from the step verdicts the wire test
# printed, which is what a rate run is actually asserting. Counting absent rows as a shortfall is
# what made every rate run report FAIL under a passing wire test.
case " $STEPS " in *" 3 "*) want_rows=1 ;; *) want_rows=0 ;; esac
step_fail=$(grep -cE "^STEP [0-9]+ RESULT FAIL|^TWOBOARD WIRE RESULT FAIL" "$LOG" 2>/dev/null || true)
step_pass=$(grep -cE "^STEP [0-9]+ RESULT PASS" "$LOG" 2>/dev/null || true)
step_fail=${step_fail:-0}; step_pass=${step_pass:-0}

{
	echo "SWEEP END     $(date -Is)"
	echo "SWEEP STEPS   $STEPS, per length rows expected: $want_rows"
	echo "SWEEP LENGTHS_COVERED $lengths of $n_sizes"
	echo "SWEEP ROWS    $total  (lengths x cages $CLIENTS x directions 2)"
	echo "SWEEP EXACT   $exact"
	echo "SWEEP BAD     $bad"
	echo "SWEEP TIMEOUT $tmo"
	echo "SWEEP STEPS   $step_pass passed, $step_fail failed"
	if [ "$want_rows" = 1 ]; then
		ok=$([ "$bad" -eq 0 ] && [ "$tmo" -eq 0 ] && [ "$total" -gt 0 ] \
		     && [ "$lengths" -eq "$n_sizes" ] && [ "$step_fail" -eq 0 ] && echo 1 || echo 0)
	else
		ok=$([ "$step_fail" -eq 0 ] && [ "$step_pass" -gt 0 ] && echo 1 || echo 0)
	fi
	if [ "$ok" = 1 ]; then
		echo "SWEEP RESULT  PASS"
	else
		echo "SWEEP RESULT  FAIL"
		grep "MISMATCH" "$RUN/per_length.txt" 2>/dev/null | head -20
		grep -E "^STEP [0-9]+ RESULT FAIL|^TWOBOARD WIRE RESULT FAIL" "$LOG" 2>/dev/null | head -10
	fi
	echo "SWEEP LOG     $LOG"
} | tee -a "$LOG"

grep -q "SWEEP RESULT  PASS" "$LOG"
