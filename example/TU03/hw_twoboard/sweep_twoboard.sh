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
BIN="${NIA_VIVADO_BIN:-vivado}"
SERIAL_A="${SERIAL_A:-}"
SERIAL_B="${SERIAL_B:-}"
IMIN="${NIA_IMIN:-64}"
IMAX="${NIA_IMAX:-9018}"
IDENSE="${NIA_IDENSE:-1518}"
ISTEP_HI="${NIA_ISTEP_HI:-97}"
EQ_BYTES="${NIA_EQ_BYTES:-15000000}"
BURST_MS="${NIA_BURST_MS:-60000}"
CLIENTS="${NIA_CLIENTS:-2}"
OUT="${OUT:-$HOME/nia_sweep}"

usage() {
	cat <<EOF
sweep_twoboard.sh <image.pdi> [label]

  NIA_CLIENTS   cages the image carries, 2 for a dual image and 1 for 400G. Default 2
  NIA_IMIN      first frame length, default 64
  NIA_IMAX      last frame length inclusive, default 9018, the LEN_MAX_HW of every image
  NIA_IDENSE    last length of the dense band, default 1518. Every integer length from
                NIA_IMIN to NIA_IDENSE is covered, because the payload fusion defect this
                sweep exists to catch is a function of len mod 32 and only a dense band
                proves every tail. Above NIA_IDENSE the sweep steps by NIA_ISTEP_HI
  NIA_ISTEP_HI  stride above the dense band, default 97. It is prime, so it is coprime with
                the 16 byte segment and the 64 byte stream beat and still visits every
                len mod 16, len mod 32 and len mod 64 class. NIA_IMAX is always included
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
dense_end=$IDENSE
[ "$dense_end" -gt "$IMAX" ] && dense_end=$IMAX
for ((i = IMIN; i <= dense_end; i++)); do sizes="$sizes $i"; done
for ((i = dense_end + ISTEP_HI; i <= IMAX; i += ISTEP_HI)); do sizes="$sizes $i"; done
case " $sizes " in *" $IMAX "*) ;; *) sizes="$sizes $IMAX" ;; esac
n_sizes=$(printf '%s\n' $sizes | wc -l)

{
	echo "SWEEP IMAGE   $LABEL"
	echo "SWEEP PDI     $PDI"
	echo "SWEEP MD5     $(md5sum "$PDI" | cut -d' ' -f1)"
	echo "SWEEP BOARDS  A=$SERIAL_A B=$SERIAL_B clients=$CLIENTS"
	echo "SWEEP LENGTHS $IMIN to $IMAX inclusive, $n_sizes lengths, $EQ_BYTES bytes each"
	echo "SWEEP BANDS   every integer $IMIN to $dense_end, then step $ISTEP_HI to $IMAX"
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

echo "== bringing the links up" | tee -a "$LOG"
NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
	"$XSDB" "$HERE/pktgen_twoboard_link.tcl" 2>&1 | tee -a "$LOG"

if ! grep -qE "STEP [0-9]+ PASS|LINK PASS|TWOBOARD PASS" "$LOG"; then
	echo "== link step reported no pass token, continuing so the traffic decides" | tee -a "$LOG"
fi

echo "== sweeping $n_sizes lengths, both directions" | tee -a "$LOG"
NIA_DPC_A="$DPC_A" NIA_DPC_B="$DPC_B" NIA_CLIENTS="$CLIENTS" \
	NIA_STEPS="1 2 3" NIA_EQ_SIZES="$sizes" NIA_EQ_BYTES="$EQ_BYTES" \
	NIA_BURST_MS="$BURST_MS" \
	"$XSDB" "$HERE/pktgen_twoboard_wire.tcl" 2>&1 | tee -a "$LOG"

grep -E "^STEP 3 len" "$LOG" > "$RUN/per_length.txt" 2>/dev/null

total=$(grep -c "^STEP 3 len" "$RUN/per_length.txt" 2>/dev/null || true)
exact=$(grep -c "EXACT" "$RUN/per_length.txt" 2>/dev/null || true)
bad=$(grep -c "MISMATCH" "$RUN/per_length.txt" 2>/dev/null || true)
tmo=$(grep -c "^STEP 3 len .* TIMEOUT" "$LOG" 2>/dev/null || true)
lengths=$(awk '{print $4}' "$RUN/per_length.txt" 2>/dev/null | sort -un | wc -l)
total=${total:-0}; exact=${exact:-0}; bad=${bad:-0}; tmo=${tmo:-0}

{
	echo "SWEEP END     $(date -Is)"
	echo "SWEEP LENGTHS_COVERED $lengths of $n_sizes"
	echo "SWEEP ROWS    $total  (lengths x cages $CLIENTS x directions 2)"
	echo "SWEEP EXACT   $exact"
	echo "SWEEP BAD     $bad"
	echo "SWEEP TIMEOUT $tmo"
	if [ "$bad" -eq 0 ] && [ "$tmo" -eq 0 ] && [ "$total" -gt 0 ] && [ "$lengths" -eq "$n_sizes" ]; then
		echo "SWEEP RESULT  PASS"
	else
		echo "SWEEP RESULT  FAIL"
		grep "MISMATCH" "$RUN/per_length.txt" 2>/dev/null | head -20
	fi
	echo "SWEEP LOG     $LOG"
} | tee -a "$LOG"

grep -q "SWEEP RESULT  PASS" "$LOG"
