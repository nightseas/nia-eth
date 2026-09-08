# ---------------------------------------------------------------------------
# File        : nia_props.sh
# Description : Reads the <image>.image_props.txt manifest that the build writes beside a device
#               image, and sets the variables the two board drivers take from it. This file is
#               sourced, not executed.
#
#               The AXI-Stream geometry register publishes the stream width, and 1024 bits is both
#               a 200G client and a 400G client, so pktgen_twoboard_lib.tcl refuses to derive the
#               line rate and exits 2 unless NIA_LINE_GBPS is set. Every driver that programs an
#               image therefore has to supply it, and NIA_RATE of the manifest is where it comes
#               from.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Bash
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

NIA_PROP_RATE=""
NIA_PROP_PKTGEN=""
NIA_PROP_CLIENTS=""
NIA_PROP_MHZ=""
NIA_PROP_IMIN=""
NIA_PROP_IMAX=""
NIA_PROP_TOP=""

nia_props_load() {
	nia_props_file="${1%.pdi}.image_props.txt"
	if [ ! -f "$nia_props_file" ]; then
		echo "nia_props: no manifest at $nia_props_file"
		return 1
	fi
	while IFS='=' read -r nia_props_k nia_props_v; do
		case "$nia_props_k" in
		NIA_RATE)       NIA_PROP_RATE="$nia_props_v" ;;
		NIA_PKTGEN)     NIA_PROP_PKTGEN="$nia_props_v" ;;
		NIA_CLIENTS)    NIA_PROP_CLIENTS="$nia_props_v" ;;
		NIA_USR_MHZ)    NIA_PROP_MHZ="$nia_props_v" ;;
		NIA_LEN_MIN_HW) NIA_PROP_IMIN="$nia_props_v" ;;
		NIA_LEN_MAX_HW) NIA_PROP_IMAX="$nia_props_v" ;;
		NIA_TOP)        NIA_PROP_TOP="$nia_props_v" ;;
		esac
	done < "$nia_props_file"
	echo "nia_props: $nia_props_file gives pktgen=$NIA_PROP_PKTGEN rate=$NIA_PROP_RATE" \
	     "clients=$NIA_PROP_CLIENTS usr_mhz=$NIA_PROP_MHZ lengths $NIA_PROP_IMIN..$NIA_PROP_IMAX"
	return 0
}

# Sets NIA_LINE_GBPS and CLIENTS from the manifest where the caller has not already set them.
# CLIENTS matters because a 400G image carries one cage and a default of 2 addresses a window
# that does not exist.
nia_props_apply() {
	nia_props_load "$1" || return 1
	if [ -z "${NIA_LINE_GBPS:-}" ] && [ -n "$NIA_PROP_RATE" ]; then
		NIA_LINE_GBPS="$NIA_PROP_RATE"
		echo "nia_props: NIA_LINE_GBPS=$NIA_LINE_GBPS from NIA_RATE of the manifest"
	fi
	if [ -z "${NIA_CLIENTS:-}" ] && [ -n "$NIA_PROP_CLIENTS" ]; then
		CLIENTS="$NIA_PROP_CLIENTS"
		echo "nia_props: clients=$CLIENTS from NIA_CLIENTS of the manifest"
	fi
	return 0
}
