# run_impl.tcl — BD 工程的综合/实现/bitstream/导出 hdf（Vivado 2018.3）
#
# 前置：build_bd.tcl 已成功跑完。产物：
#   C:/yshlearn/FPGA_learn/RL_project_bd/sdk/   （.hdf + .bit）
#   C:/yshlearn/FPGA_learn/RL_project_bd/*.rpt  （时序/利用率报告）

set ROOT C:/yshlearn/FPGA_learn/RL_project_bd
set PROJ $ROOT/bd_proj

open_project $PROJ/net_v_bd.xpr

# --- 给所有综合 run 挂 PRE hook（见 copy_hex.tcl 注释）---
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] {
    set_property STEPS.SYNTH_DESIGN.TCL.PRE $ROOT/tcl/copy_hex.tcl [get_runs $r]
    puts "HOOK_PRE $r"
}

# --- 先跑 IP OOC 综合 run ---
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] {
    if {$r ne "synth_1"} {
        launch_runs $r -jobs 8
        wait_on_run $r
        set st [get_property status [get_runs $r]]
        puts "RUN_STATUS $r : $st"
        if {[regexp -nocase {failed|error} $st]} {
            puts "FATAL_OOC_SYNTH $r"
            exit 1
        }
    }
}

# --- 顶层综合 ---
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property status [get_runs synth_1]]
puts "RUN_STATUS synth_1 : $st"
if {[regexp -nocase {failed|error} $st]} { puts "FATAL_SYNTH"; exit 1 }

open_run synth_1
report_timing_summary -file $ROOT/synth_timing_summary.rpt
set sp [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $sp] > 0} {
    puts "SYNTH_WNS: [get_property SLACK $sp]"
}

# --- 实现 + bitstream ---
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st [get_property status [get_runs impl_1]]
puts "RUN_STATUS impl_1 : $st"
if {[regexp -nocase {failed|error} $st]} { puts "FATAL_IMPL"; exit 1 }
puts "IMPL_WNS: [get_property STATS.WNS [get_runs impl_1]]"
puts "IMPL_WHS: [get_property STATS.WHS [get_runs impl_1]]"
puts "IMPL_WTP: [get_property STATS.WTP [get_runs impl_1]]"

open_run impl_1
report_timing_summary -file $ROOT/impl_timing_summary.rpt
report_utilization   -file $ROOT/impl_utilization.rpt

# --- 导出硬件到 RL_project_bd/sdk/ ---
# 2018.3 没有 export_hardware：write_hwdef 出 hwdef，write_sysdef 把 bit 打进 hdf
file mkdir $ROOT/sdk
file mkdir $PROJ/net_v_bd.sdk
set hwdef $PROJ/net_v_bd.sdk/net_v_bd.hwdef
set hdf   $ROOT/sdk/net_v_bd.hdf
write_hwdef -force -file $hwdef
set bit [glob -nocomplain $PROJ/net_v_bd.runs/impl_1/*.bit]
puts "BIT_FOUND: $bit"
if {[llength $bit] > 0} {
    write_sysdef -force -hwdef $hwdef -bitfile [lindex $bit 0] -file $hdf
    file copy -force [lindex $bit 0] $ROOT/sdk/
} else {
    file copy -force $hwdef $hdf
    puts "WARN_NO_BIT_IN_HDF"
}
puts "SDK_DIR_CONTENTS: [glob -nocomplain $ROOT/sdk/*]"
puts "IMPL_DONE"
