# rebuild_all.tcl — 补齐 fsbl_bsp / pmufw_bsp 编译（第二轮）
set WS C:/yshlearn/FPGA_learn/RL_project_sdk/ws
setws $WS
if {[catch {projects -build} e]} {
    puts "BUILD_ALL_ERROR: $e"
}
foreach p {net_v_app fsbl pmufw} {
    set elf [glob -nocomplain $WS/$p/Debug/*.elf]
    if {[llength $elf] > 0} {
        foreach e $elf { puts "ELF_OK_$p: $e size=[file size $e]" }
    } else {
        puts "ELF_MISSING_$p"
    }
}
puts "REBUILD_DONE"
