#!/usr/bin/env bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PDI="${1:-}"
LABEL="${2:-$(basename "${PDI:-none}" .pdi)}"
CYCLES="${NIA_CYCLES:-30}"
CLIENTS="${NIA_CLIENTS:-2}"
XSDB="${NIA_XSDB:-xsdb}"
BIN="${NIA_VIVADO_BIN:-vivado_lab}"
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"
OUT="${OUT:-$HOME/nia_cycle}"
SKIP_PROGRAM="${NIA_SKIP_PROGRAM:-0}"
PROGRAM_TRIES="${NIA_PROGRAM_TRIES:-3}"

if [ -z "$PDI" ] || [ ! -f "$PDI" ]; then
	echo "cycle_twoboard.sh <image.pdi> [label]"
	echo "  NIA_CYCLES   cycles to run, default 30"
	echo "  NIA_CLIENTS  cages the image carries, default 2"
	echo "  SERIAL_A     JTAG cable serial of board A, required"
	echo "  SERIAL_B     JTAG cable serial of board B, required"
	echo "  NIA_SKIP_PROGRAM=1 runs the read and traffic part only"
	exit 2
fi
[ -n "$SERIAL_A" ] && [ -n "$SERIAL_B" ] || { echo "cycle: set SERIAL_A and SERIAL_B"; exit 2; }

RUN="$OUT/${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"

# pktgen_twoboard_lib.tcl exits 2 on a 1024 bit AXI-Stream image unless NIA_LINE_GBPS is set,
# because the geometry register publishes the stream width and 1024 bits is both 200G and 400G.
# The manifest beside the image carries the rate, so take it from there.
. "$HERE/nia_props.sh"
nia_props_apply "$PDI" || true
if [ -n "${NIA_LINE_GBPS:-}" ]; then export NIA_LINE_GBPS; fi
LOG="$RUN/cycle.log"
CSV="$RUN/cycles.csv"

echo "cycle,timestamp,result,first_a_up_aligned,first_b_up_aligned,ms_to_up,link_fault,access_fault,retry,transitions,mismatch_beats,err_frames,detail" > "$CSV"

{
	echo "CYCLE RUN     $LABEL"
	echo "CYCLE PDI     $PDI"
	echo "CYCLE MD5     $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "CYCLE BOARDS  A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS"
	echo "CYCLE COUNT   $CYCLES"
	echo "CYCLE START   $(date -Is)"
} | tee -a "$LOG"

pass=0
fail=0
prog_retries=0
for ((i = 1; i <= CYCLES; i++)); do
	echo "===== CYCLE $i of $CYCLES $(date -Is)" | tee -a "$LOG"
	if [ "$SKIP_PROGRAM" = 0 ]; then
		prog_rc=1
		prog_try=0
		while [ "$prog_try" -lt "$PROGRAM_TRIES" ] && [ "$prog_rc" != 0 ]; do
			prog_try=$((prog_try + 1))
			SERIAL_A="$SERIAL_A" SERIAL_B="$SERIAL_B" NIA_VIVADO_BIN="$BIN" \
				"$HERE/program_twoboard.sh" program "$PDI" "$PDI" >> "$LOG" 2>&1
			prog_rc=$?
			if [ "$prog_rc" != 0 ]; then
				echo "CYCLE $i programming attempt $prog_try returned $prog_rc, the tool crashed rather than the link failing" | tee -a "$LOG"
				prog_retries=$((prog_retries + 1))
				sleep 5
			fi
		done
		if [ "$prog_rc" != 0 ]; then
			echo "$i,$(date +%Y-%m-%dT%H:%M:%S),FAIL,-,-,-1,0,0,0,0,0,0,\"programming returned $prog_rc after $prog_try attempts\"" >> "$CSV"
			fail=$((fail + 1))
			echo "CYCLE $i RESULT FAIL programming returned $prog_rc after $prog_try attempts" | tee -a "$LOG"
			continue
		fi
	fi

	"$XSDB" "$HERE/dpc_ids.tcl" > "$RUN/dpc_$i.txt" 2>&1
	DPC_A="$(awk -v s="$SERIAL_A" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	DPC_B="$(awk -v s="$SERIAL_B" '$1 == "DPCID" && $2 == s {print $3}' "$RUN/dpc_$i.txt" | head -1)"
	if [ -z "$DPC_A" ] || [ -z "$DPC_B" ]; then
		cat "$RUN/dpc_$i.txt" >> "$LOG"
		echo "$i,$(date +%Y-%m-%dT%H:%M:%S),FAIL,-,-,-1,0,0,0,0,0,0,\"no DPC target id for a serial\"" >> "$CSV"
		fail=$((fail + 1))
		echo "CYCLE $i RESULT FAIL no DPC target id" | tee -a "$LOG"
		continue
	fi

	NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
		NIA_CYCLE="$i" NIA_CSV="$CSV" \
		"$XSDB" "$HERE/pktgen_twoboard_cycle.tcl" >> "$LOG" 2>&1
	rc=$?
	if [ "$rc" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		if ! grep -q "^$i," "$CSV"; then
			echo "$i,$(date +%Y-%m-%dT%H:%M:%S),FAIL,-,-,-1,0,0,0,0,0,0,\"cycle script exit $rc\"" >> "$CSV"
		fi
	fi
	tail -n 3 "$LOG" | grep -E "^CYCLE $i RESULT" || true
done

{
	echo "CYCLE END     $(date -Is)"
	echo "CYCLE PASS    $pass"
	echo "CYCLE FAIL    $fail"
	echo "CYCLE PROGRAM_RETRIES $prog_retries"
	if [ "$fail" -eq 0 ] && [ "$pass" -eq "$CYCLES" ]; then
		echo "CYCLE RESULT  PASS $pass of $CYCLES"
	else
		echo "CYCLE RESULT  FAIL $fail of $CYCLES"
		grep ",FAIL," "$CSV" | head -20
	fi
	echo "CYCLE CSV     $CSV"
	echo "CYCLE LOG     $LOG"
} | tee -a "$LOG"

[ "$fail" -eq 0 ]
