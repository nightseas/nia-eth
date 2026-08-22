# ---------------------------------------------------------------------------
# File        : dcmac_fifo_ip.tcl
# Description : Generates the two AXI-Stream FIFO IP the adapter binds: one clock crossing
#               FIFO and one packet mode FIFO, at the width the stream side uses.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

if {[info exists NIA_FIFO_IP_DIR]} {
    set ip_dir $NIA_FIFO_IP_DIR
} elseif {$argc >= 1} {
    set ip_dir [lindex $argv 0]
} else {
    set ip_dir "./ip_fifo"
}
if {$argc >= 2} { set part [lindex $argv 1] } else { set part "xcvp1552-vsva2785-2MHP-i-S" }

file mkdir $ip_dir

if {[catch {current_project}]} {
    create_project -in_memory -part $part
}
set_property ip_output_repo $ip_dir [current_project]

set DATA_BYTES   64
set TUSER_W       1
set CDC_DEPTH   512
set PKT_DEPTH   256

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 \
          -module_name nia_fifo_cdc_512x1 -dir $ip_dir
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES          $DATA_BYTES \
    CONFIG.TUSER_WIDTH              $TUSER_W \
    CONFIG.TID_WIDTH                0 \
    CONFIG.TDEST_WIDTH              0 \
    CONFIG.HAS_TKEEP                1 \
    CONFIG.HAS_TLAST                1 \
    CONFIG.HAS_TSTRB                0 \
    CONFIG.FIFO_DEPTH               $CDC_DEPTH \
    CONFIG.FIFO_MODE                1 \
    CONFIG.IS_ACLK_ASYNC            1 \
    CONFIG.SYNCHRONIZATION_STAGES   3 \
    CONFIG.FIFO_MEMORY_TYPE         auto \
    CONFIG.HAS_PROG_FULL            0 \
    CONFIG.HAS_PROG_EMPTY           0 \
    CONFIG.HAS_WR_DATA_COUNT        0 \
    CONFIG.HAS_RD_DATA_COUNT        0 \
    CONFIG.ENABLE_ECC               0 \
] [get_ips nia_fifo_cdc_512x1]

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 \
          -module_name nia_fifo_pkt_512x1 -dir $ip_dir
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES          $DATA_BYTES \
    CONFIG.TUSER_WIDTH              $TUSER_W \
    CONFIG.TID_WIDTH                0 \
    CONFIG.TDEST_WIDTH              0 \
    CONFIG.HAS_TKEEP                1 \
    CONFIG.HAS_TLAST                1 \
    CONFIG.HAS_TSTRB                0 \
    CONFIG.FIFO_DEPTH               $PKT_DEPTH \
    CONFIG.FIFO_MODE                2 \
    CONFIG.IS_ACLK_ASYNC            0 \
    CONFIG.FIFO_MEMORY_TYPE         auto \
    CONFIG.HAS_PROG_FULL            0 \
    CONFIG.HAS_PROG_EMPTY           0 \
    CONFIG.HAS_WR_DATA_COUNT        0 \
    CONFIG.HAS_RD_DATA_COUNT        0 \
    CONFIG.ENABLE_ECC               0 \
] [get_ips nia_fifo_pkt_512x1]

foreach ip {nia_fifo_cdc_512x1 nia_fifo_pkt_512x1} {
    generate_target {instantiation_template synthesis simulation} [get_ips $ip]
    puts "NIA_FIFO_IP $ip \
TDATA_NUM_BYTES=[get_property CONFIG.TDATA_NUM_BYTES [get_ips $ip]] \
TUSER_WIDTH=[get_property CONFIG.TUSER_WIDTH [get_ips $ip]] \
HAS_TKEEP=[get_property CONFIG.HAS_TKEEP [get_ips $ip]] \
HAS_TLAST=[get_property CONFIG.HAS_TLAST [get_ips $ip]] \
FIFO_DEPTH=[get_property CONFIG.FIFO_DEPTH [get_ips $ip]] \
FIFO_MODE=[get_property CONFIG.FIFO_MODE [get_ips $ip]] \
IS_ACLK_ASYNC=[get_property CONFIG.IS_ACLK_ASYNC [get_ips $ip]]"
    set stub [get_files -quiet -of_objects [get_ips $ip] "*/sim/${ip}.v"]
    if {$stub ne ""} {
        set fh [open [lindex $stub 0] r]; set txt [read $fh]; close $fh
        puts "NIA_FIFO_PORTS $ip m_axis_aresetn=[regexp -all {m_axis_aresetn} $txt] \
m_axis_aclk=[regexp -all {m_axis_aclk} $txt] \
m_axis_tuser=[regexp -all {m_axis_tuser} $txt]"
    } else {
        puts "NIA_FIFO_PORTS $ip stub=NOT_FOUND"
    }
}
puts "NIA_FIFO_IP_DIR $ip_dir"
puts "NIA_FIFO_IP_DONE"
