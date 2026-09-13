#!/usr/bin/env bash
# Programs the image and reads the link, repeating until a cage does not come up, then stops
# with the board left in that state: no restart is issued, nothing is reprogrammed after the
# failure, so an eye scan or a register probe sees the failed transceiver.
#
# Usage: hold_on_fail.sh <pdi> [max attempts] [wait ms before the read]
#
# The wait covers the supervisor recovery attempts: LINK_WDT_MS is 750 ms and a repair takes
# about one second, so 10000 ms is about nine recovery attempts. A cage still down after it is
# a cage the supervisor did not recover.
PDI="$1"
MAX="${2:-40}"
WAIT_MS="${3:-10000}"
OUT="${4:-$HOME/t4_lab/hold_on_fail}"
mkdir -p "$OUT"

. /tools/Xilinx/2025.2/Vivado/settings64.sh > /dev/null 2>&1
pgrep -x hw_server > /dev/null || { setsid nohup hw_server -d > /tmp/hw_server.log 2>&1 < /dev/null & sleep 6; }

cat > "$OUT/prog.tcl" <<EOT
open_hw_manager
connect_hw_server -url TCP:localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xcvp1552*] 0]
current_hw_device \$dev
set_property PROGRAM.FILE $PDI \$dev
program_hw_devices \$dev
close_hw_target
close_hw_manager
EOT

for i in $(seq 1 "$MAX"); do
	echo "HOLD attempt $i of $MAX $(date -Is)" | tee -a "$OUT/log"
	vivado -mode batch -source "$OUT/prog.tcl" -nojournal -nolog > "$OUT/program_$i.log" 2>&1
	if ! grep -q "Successfully programmed" "$OUT/program_$i.log"; then
		echo "HOLD PROGRAM_FAIL attempt $i" | tee -a "$OUT/log"
		exit 1
	fi
	sleep "$(awk -v m="$WAIT_MS" 'BEGIN {printf "%.1f", m / 1000.0}')"
	cd "$HOME/nia_hw_g4/hw" || exit 1
	NIA_SAMPLES=3 NIA_SAMPLE_MS=200 xsdb linkread.tcl > "$OUT/read_$i.log" 2>&1
	grep -E "^LINKREAD" "$OUT/read_$i.log" | tee -a "$OUT/log"
	failed=$(grep -m1 "LINKREAD FAILED_CAGE" "$OUT/read_$i.log" | sed 's/.*FAILED_CAGE //')
	if [ "$failed" != "none" ]; then
		echo "HOLD STOPPED at attempt $i, cage(s) $failed did not come up after $WAIT_MS ms" | tee -a "$OUT/log"
		echo "HOLD the board holds this state: no restart was issued and nothing was reprogrammed" | tee -a "$OUT/log"
		exit 0
	fi
done
echo "HOLD every one of $MAX attempts came up, nothing to hold" | tee -a "$OUT/log"
exit 2
