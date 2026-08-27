#!/usr/bin/env bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PDI="${1:-}"
LABEL="${2:-$(basename "${PDI:-none}" .pdi)}"
CYCLES="${NIA_CYCLES:-20}"
CLIENTS="${NIA_CLIENTS:-2}"
XSDB="${NIA_XSDB:-xsdb}"
BIN="${NIA_VIVADO_BIN:-vivado_lab}"
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"
OUT="${OUT:-$HOME/nia_remedy}"

[ -n "$PDI" ] && [ -f "$PDI" ] || { echo "remedy_twoboard.sh <image.pdi> [label]"; exit 2; }
[ -n "$SERIAL_A" ] && [ -n "$SERIAL_B" ] || { echo "diag: set SERIAL_A and SERIAL_B"; exit 2; }

RUN="$OUT/${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"
LOG="$RUN/remedy.log"
CSV="$RUN/remedy.csv"
echo "cycle,timestamp,first,first_a,first_b,first_ms,r1,r1_ms,r2,r2_ms,r3,r3_ms,r4,r4_ms" > "$CSV"

{
	echo "REMEDY RUN    $LABEL"
	echo "REMEDY PDI    $PDI md5 $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "REMEDY BOARDS A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS cycles=$CYCLES"
	echo "REMEDY START  $(date -Is)"
} | tee -a "$LOG"

for ((i = 1; i <= CYCLES; i++)); do
	echo "===== REMEDY CYCLE $i of $CYCLES $(date -Is)" | tee -a "$LOG"
	SERIAL_A="$SERIAL_A" SERIAL_B="$SERIAL_B" NIA_VIVADO_BIN="$BIN" \
		"$HERE/program_twoboard.sh" program "$PDI" "$PDI" >> "$LOG" 2>&1 || {
		echo "REMEDY $i programming failed" | tee -a "$LOG"; continue; }

	"$XSDB" "$HERE/dpc_ids.tcl" > "$RUN/dpc_$i.txt" 2>&1
	DPC_A="$(awk -v s="$SERIAL_A" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	DPC_B="$(awk -v s="$SERIAL_B" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	[ -n "$DPC_A" ] && [ -n "$DPC_B" ] || { echo "REMEDY $i no DPC id" | tee -a "$LOG"; continue; }

	NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
		NIA_CYCLE="$i" NIA_CSV="$CSV" \
		"$XSDB" "$HERE/pktgen_twoboard_remedy.tcl" >> "$LOG" 2>&1
	grep -E "^REMEDY (resync|rxdp|txdp|restart) RESULT" "$LOG" | tail -4
done

{
	echo "REMEDY END    $(date -Is)"
	echo "REMEDY DOWN   $(grep -c ",DOWN," "$CSV")"
	echo "REMEDY CSV    $CSV"
} | tee -a "$LOG"
