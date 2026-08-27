#!/usr/bin/env bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PDI="${1:-}"
LABEL="${2:-$(basename "${PDI:-none}" .pdi)}"
CLIENTS="${NIA_CLIENTS:-2}"
XSDB="${NIA_XSDB:-xsdb}"
BIN="${NIA_VIVADO_BIN:-vivado_lab}"
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"
OUT="${OUT:-$HOME/nia_stats}"
SKIP_PROGRAM="${NIA_SKIP_PROGRAM:-0}"

[ -n "$PDI" ] && [ -f "$PDI" ] || { echo "stats_twoboard.sh <image.pdi> [label]"; exit 2; }
[ -n "$SERIAL_A" ] && [ -n "$SERIAL_B" ] || { echo "stats: set SERIAL_A and SERIAL_B"; exit 2; }

RUN="$OUT/${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"
LOG="$RUN/stats.log"

{
	echo "STATS RUN    $LABEL"
	echo "STATS PDI    $PDI md5 $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "STATS BOARDS A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS"
	echo "STATS START  $(date -Is)"
} | tee -a "$LOG"

if [ "$SKIP_PROGRAM" = 0 ]; then
	SERIAL_A="$SERIAL_A" SERIAL_B="$SERIAL_B" NIA_VIVADO_BIN="$BIN" \
		"$HERE/program_twoboard.sh" program "$PDI" "$PDI" >> "$LOG" 2>&1 || {
		echo "STATS programming failed" | tee -a "$LOG"; exit 1; }
	sleep 15
fi

"$XSDB" "$HERE/dpc_ids.tcl" > "$RUN/dpc.txt" 2>&1
DPC_A="$(awk -v s="$SERIAL_A" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc.txt" | head -1)"
DPC_B="$(awk -v s="$SERIAL_B" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc.txt" | head -1)"
[ -n "$DPC_A" ] && [ -n "$DPC_B" ] || { echo "STATS no DPC id" | tee -a "$LOG"; exit 1; }

NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
	"$XSDB" "$HERE/pktgen_twoboard_stats.tcl" 2>&1 | tee -a "$LOG"

echo "STATS END    $(date -Is)" | tee -a "$LOG"
echo "STATS LOG    $LOG"
