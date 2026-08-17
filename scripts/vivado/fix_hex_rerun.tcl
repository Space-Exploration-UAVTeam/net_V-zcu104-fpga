# fix_hex_rerun.tcl — 给 OOC 综合 run 补 hex hook 并重跑（Vivado 2018.3）
#
# 背景：BD 默认 "OOC per IP" 综合，net_v_axi 的 OOC run 对象在首次
#   launch_runs 前不存在，导致 run_impl.tcl 的 hook 循环只挂到了 synth_1，
#   IP OOC 综合找不到 data/hex/*.hex（Synth 8-4445），bias/ELU ROM 被清零。
#   本脚本在 run 对象已存在后执行：补 hook → 重置 → 重跑 → 重新导出。
#   同时打印 BD 文件属性，确认 synth_mode 属性名（供 run_impl 改进参考）。

set ROOT C:/yshlearn/FPGA_learn/RL_project_bd
set PROJ $ROOT/bd_proj

open_project $PROJ/net_v_bd.xpr

puts "ALL_RUNS: [get_runs]"
catch { report_property [get_files design_1.bd] } rp
puts "BD_FILE_PROPS_BEGIN"
puts $rp
puts "BD_FILE_PROPS_END"

# --- 给全部综合 run（含 OOC）挂 hex hook ---
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] {
    set_property STEPS.SYNTH_DESIGN.TCL.PRE $ROOT/tcl/copy_hex.tcl [get_runs $r]
    puts "HOOK_PRE $r"
}

# --- 重置 OOC run + 顶层/实现，重跑整条链 ---
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] {
    if {$r ne "synth_1"} {
        reset_run $r
        puts "RESET $r"
    }
}
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property status [get_runs synth_1]]
puts "RUN_STATUS synth_1 : $st"
if {[regexp -nocase {failed|error} $st]} { puts "FATAL_SYNTH"; exit 1 }
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] {
    puts "RUN_STATUS $r : [get_property status [get_runs $r]]"
}

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

# --- 重新导出硬件（write_hwdef + write_sysdef 把 bit 打进 hdf）---
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
puts "FIX_RERUN_DONE"
