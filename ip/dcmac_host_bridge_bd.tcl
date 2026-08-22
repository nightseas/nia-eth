# ---------------------------------------------------------------------------
# File        : dcmac_host_bridge_bd.tcl
# Description : Builds the host bridge block design that presents the register aperture to
#               a host, at the base address and size it is given, and records the pins it
#               created.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set DCMAC_HOST_BRIDGE_NAME     dcmac_host_bridge
set DCMAC_HOST_BRIDGE_MANIFEST bd_manifest.txt

proc dcmac_host_bridge_manifest {bd_dir} {
  return [file join $bd_dir $::DCMAC_HOST_BRIDGE_MANIFEST]
}

proc dcmac_host_bridge_read {bd_dir} {
  set manifest [dcmac_host_bridge_manifest $bd_dir]
  if {![file exists $manifest]} {
    return [list]
  }
  set fh [open $manifest r]
  set text [read $fh]
  close $fh
  set paths [list]
  foreach line [split $text "\n"] {
    set line [string trim $line]
    if {$line ne "" && [file exists $line]} { lappend paths $line }
  }
  return $paths
}

proc dcmac_host_bridge_report_pins {cell} {
  foreach intf [lsort [get_bd_intf_pins -quiet $cell/*]] {
    puts "BRIDGE INTF [get_property MODE $intf] [get_property NAME $intf]"
  }
  foreach pin [lsort [get_bd_pins -quiet $cell/*]] {
    puts "BRIDGE PIN [get_property DIR $pin] [get_property NAME $pin]"
  }
}

proc dcmac_host_bridge_create {bd_dir part window_base window_bytes aclk_hz} {
  set name $::DCMAC_HOST_BRIDGE_NAME
  file mkdir $bd_dir
  create_project -force -part $part ${name}_project [file join $bd_dir project]
  set_property target_language Verilog [current_project]

  create_bd_design $name

  set cips [create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips:3.4 versal_cips]
  set_property -dict [list \
    CONFIG.PS_PMC_CONFIG { \
      DESIGN_MODE {0} \
      PS_BOARD_INTERFACE {Custom} \
      PMC_REF_CLK_FREQMHZ {50} \
      PMC_CRP_PL0_REF_CTRL_FREQMHZ {100} \
      PS_NUM_FABRIC_RESETS {1} \
      PS_USE_M_AXI_FPD {1} \
      PS_USE_PMCPL_CLK0 {1} \
    } \
  ] $cips
  dcmac_host_bridge_report_pins versal_cips

  set convert [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil_convert]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] $convert

  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 axil_reset

  set aclk [create_bd_port -dir I -type clk axil_aclk]
  set_property -dict [list CONFIG.FREQ_HZ $aclk_hz CONFIG.ASSOCIATED_BUSIF {m_axil}] $aclk

  set pl_resetn [create_bd_port -dir O -type rst pl_resetn]

  set m_axil [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 m_axil]
  set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32} \
                           CONFIG.ADDR_WIDTH {16} CONFIG.FREQ_HZ $aclk_hz] $m_axil

  connect_bd_net $aclk \
    [get_bd_pins versal_cips/m_axi_fpd_aclk] \
    [get_bd_pins axil_convert/aclk] \
    [get_bd_pins axil_reset/slowest_sync_clk]

  connect_bd_net [get_bd_pins versal_cips/pl0_resetn] \
    [get_bd_pins axil_reset/ext_reset_in] $pl_resetn

  connect_bd_net [get_bd_pins axil_reset/peripheral_aresetn] [get_bd_pins axil_convert/aresetn]

  connect_bd_intf_net [get_bd_intf_pins versal_cips/M_AXI_FPD] [get_bd_intf_pins axil_convert/S00_AXI]
  connect_bd_intf_net $m_axil [get_bd_intf_pins axil_convert/M00_AXI]

  assign_bd_address -offset $window_base -range $window_bytes \
    -target_address_space [get_bd_addr_spaces versal_cips/M_AXI_FPD] \
    [get_bd_addr_segs m_axil/Reg] -force

  foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces versal_cips/M_AXI_FPD]] {
    puts "BRIDGE WINDOW [get_property NAME $seg] [get_property OFFSET $seg] [get_property RANGE $seg]"
  }

  validate_bd_design
  save_bd_design

  set bd_file [get_files ${name}.bd]
  if {[llength $bd_file] != 1} {
    error "BRIDGE FAIL: ${name}.bd resolved to [llength $bd_file] file(s): $bd_file"
  }
  set_property synth_checkpoint_mode None [get_files $bd_file]
  generate_target all [get_files $bd_file]
  make_wrapper -files [get_files $bd_file] -top -import

  set bd_sources [get_files -quiet -compile_order sources -used_in synthesis \
                    -of_objects [get_files $bd_file]]
  puts "BRIDGE SOURCES [llength $bd_sources]"
  foreach cell {versal_cips axil_convert axil_reset} {
    set n 0
    foreach f $bd_sources { if {[string match "*${name}_${cell}_0*" $f]} { incr n } }
    if {$n == 0} {
      error "BRIDGE FAIL: $cell contributes no synthesis source, so global synthesis of the block design would find no module for it"
    }
    puts "BRIDGE SOURCE COUNT $cell $n"
  }

  set wrapper [get_files -quiet ${name}_wrapper.v]
  if {[llength $wrapper] != 1} {
    set wrapper [get_files -quiet ${name}_wrapper.sv]
  }
  if {[llength $wrapper] != 1} {
    error "BRIDGE FAIL: make_wrapper produced no single ${name}_wrapper source: $wrapper"
  }
  set wrapper [file normalize $wrapper]

  set mf [open [dcmac_host_bridge_manifest $bd_dir] w]
  puts $mf [file normalize $bd_file]
  puts $mf $wrapper
  close $mf

  puts "BRIDGE BD [file normalize $bd_file]"
  puts "BRIDGE WRAPPER $wrapper"
  set fh [open $wrapper r]
  set text [read $fh]
  close $fh
  foreach line [split $text "\n"] {
    if {[regexp {^\s*(input|output|inout)} $line]} { puts "BRIDGE PORT [string trim $line]" }
  }
  close_project
  return $wrapper
}
