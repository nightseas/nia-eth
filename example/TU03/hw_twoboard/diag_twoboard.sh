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
OUT="${OUT:-$HOME/nia_diag}"

[ -n "$PDI" ] && [ -f "$PDI" ] || { echo "diag_twoboard.sh <image.pdi> [label]"; exit 2; }
[ -n "$SERIAL_A" ] && [ -n "$SERIAL_B" ] || { echo "diag: set SERIAL_A and SERIAL_B"; exit 2; }

RUN="$OUT/${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"

# pktgen_twoboard_lib.tcl exits 2 on a 1024 bit AXI-Stream image unless NIA_LINE_GBPS is set,
# because the geometry register publishes the stream width and 1024 bits is both 200G and 400G.
# The manifest beside the image carries the rate, so take it from there.
. "$HERE/nia_props.sh"
nia_props_apply "$PDI" || true
if [ -n "${NIA_LINE_GBPS:-}" ]; then export NIA_LINE_GBPS; fi
LOG="$RUN/diag.log"
CSV="$RUN/diag.csv"
echo "cycle,timestamp,first,first_a,first_b,first_ms,restart1,restart1_ms,restart2,restart2_ms,restart3,restart3_ms" > "$CSV"

{
	echo "DIAG RUN    $LABEL"
	echo "DIAG PDI    $PDI md5 $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "DIAG BOARDS A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS cycles=$CYCLES"
	echo "DIAG START  $(date -Is)"
} | tee -a "$LOG"

for ((i = 1; i <= CYCLES; i++)); do
	echo "===== DIAG CYCLE $i of $CYCLES $(date -Is)" | tee -a "$LOG"
	SERIAL_A="$SERIAL_A" SERIAL_B="$SERIAL_B" NIA_VIVADO_BIN="$BIN" \
		"$HERE/program_twoboard.sh" program "$PDI" "$PDI" >> "$LOG" 2>&1 || {
		echo "DIAG $i programming failed" | tee -a "$LOG"; continue; }

	"$XSDB" "$HERE/dpc_ids.tcl" > "$RUN/dpc_$i.txt" 2>&1
	DPC_A="$(awk -v s="$SERIAL_A" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	DPC_B="$(awk -v s="$SERIAL_B" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	[ -n "$DPC_A" ] && [ -n "$DPC_B" ] || { echo "DIAG $i no DPC id" | tee -a "$LOG"; continue; }

	NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
		NIA_CYCLE="$i" NIA_CSV="$CSV" \
		"$XSDB" "$HERE/pktgen_twoboard_diag.tcl" >> "$LOG" 2>&1
	grep -E "^DIAG $i (FIRST|RESTART)" "$LOG" | tail -6
done

{
	echo "DIAG END    $(date -Is)"
	echo "DIAG DOWN   $(grep -c ",DOWN," "$CSV")"
	echo "DIAG CSV    $CSV"
} | tee -a "$LOG"
