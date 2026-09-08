# The memory the crossing and packet FIFOs are built from. 'auto' lets the IP choose, which
# has always given block RAM at these depths and widths. 'ultra' forces URAM288E5, of which
# this part has 1301 and the design uses none, so it is free area; the reason it is not the
# default is that a deep URAM cascade limits Fmax, which is why
# nia-dev/artifacts/coyote-tu03/.../nia_uram_sdp.sv banks the array and registers both the
# address decode and the read multiplexer. Try it when a failing endpoint lands on FIFO
# memory pins, and not before: the ranking of a400rx put 0 of 1627 there.
set nia_fifo_mem [expr {[info exists ::env(NIA_FIFO_MEM)] ? $::env(NIA_FIFO_MEM) : "auto"}]
if {[lsearch -exact {auto block ultra distributed} $nia_fifo_mem] < 0} {
    puts "NIA_FIFO_IP FAIL: NIA_FIFO_MEM=$nia_fifo_mem is not one of auto, block, ultra, distributed"
    exit 2
}
# The crossing FIFO keeps IS_ACLK_ASYNC 1 and the packet FIFO is synchronous. Setting
# FIFO_MEMORY_TYPE to ultra on the crossing FIFO makes the IP drop its second clock, and the
# result is the synthesis error "named port connection m_axis_aclk does not exist" from
# eth_axis_async_fifo.sv, which is how g400rx_uram and g200full_uram failed. The setting is
# therefore applied to the packet FIFO only, and the crossing FIFO keeps auto.
set nia_fifo_mem_cdc $nia_fifo_mem
if {$nia_fifo_mem eq "ultra"} {
    set nia_fifo_mem_cdc "auto"
    puts "NIA_FIFO_IP NOTE the crossing FIFO keeps auto, because ultra removes its second\
 clock and it is asynchronous"
}
puts "NIA_FIFO_IP MEMORY_TYPE packet=$nia_fifo_mem crossing=$nia_fifo_mem_cdc"

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

set TUSER_W       1
set CDC_DEPTH   512
set PKT_DEPTH   256
set STREAM_BITS {512 1024}

foreach bits $STREAM_BITS {
set DATA_BYTES [expr {$bits / 8}]

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 \
          -module_name nia_fifo_cdc_${bits}x1 -dir $ip_dir
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
    CONFIG.FIFO_MEMORY_TYPE         $nia_fifo_mem_cdc \
    CONFIG.HAS_PROG_FULL            0 \
    CONFIG.HAS_PROG_EMPTY           0 \
    CONFIG.HAS_WR_DATA_COUNT        0 \
    CONFIG.HAS_RD_DATA_COUNT        0 \
    CONFIG.ENABLE_ECC               0 \
] [get_ips nia_fifo_cdc_${bits}x1]

create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 \
          -module_name nia_fifo_pkt_${bits}x1 -dir $ip_dir
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
    CONFIG.FIFO_MEMORY_TYPE         $nia_fifo_mem \
    CONFIG.HAS_PROG_FULL            0 \
    CONFIG.HAS_PROG_EMPTY           0 \
    CONFIG.HAS_WR_DATA_COUNT        0 \
    CONFIG.HAS_RD_DATA_COUNT        0 \
    CONFIG.ENABLE_ECC               0 \
] [get_ips nia_fifo_pkt_${bits}x1]
}

set NIA_FIFO_IPS {}
foreach bits $STREAM_BITS {
    lappend NIA_FIFO_IPS nia_fifo_cdc_${bits}x1 nia_fifo_pkt_${bits}x1
}
foreach ip $NIA_FIFO_IPS {
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
