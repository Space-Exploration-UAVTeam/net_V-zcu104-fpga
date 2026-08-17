# fix_lwip_bsp.tcl — 直接改 system.mss 加 lwip202，再重新生成/编译（SDK 2018.3）
#
# 背景：xsct 的 setlib 对已存在工程静默不落盘（getlibs 仍 No libs），
#       改为文本级在 mss 末尾追加 BEGIN LIBRARY 段（mss 是 BSP 的唯一事实源，
#       构建时按它重新生成 libsrc/include）。幂等：已有 lwip202 则跳过。

set ROOT C:/yshlearn/FPGA_learn/RL_project_sdk
set WS   $ROOT/ws
set MSS  $WS/bsp0/system.mss

set f [open $MSS r]
set d [read $f]
close $f
if {[string first "lwip202" $d] >= 0} {
    puts "MSS_ALREADY_HAS_LWIP"
} else {
    if {![string match "*\n" $d]} { append d "\n" }
    append d "\nBEGIN LIBRARY\n"
    append d " PARAMETER LIBRARY_NAME = lwip202\n"
    append d " PARAMETER LIBRARY_VER = 1.2\n"
    append d " PARAMETER PROC_INSTANCE = psu_cortexa53_0\n"
    append d " PARAMETER lwip_dhcp = false\n"
    append d " PARAMETER dhcp_does_arp_check = false\n"
    append d "END\n"
    set f [open $MSS w]
    puts -nonewline $f $d
    close $f
    puts "MSS_LWIP_ADDED"
}

setws $WS
if {[catch {regenbsp -bsp bsp0} e]} {
    puts "REGENBSP_NOTE: $e"
}

if {[catch {projects -build -type bsp -name bsp0} e]} {
    puts "BSP_BUILD_ERROR: $e"
}
if {[catch {projects -build -type app -name net_v_app} e]} {
    puts "APP_BUILD_ERROR: $e"
}

puts "LWIP_LIBSRC: [glob -nocomplain -types d $WS/bsp0/psu_cortexa53_0/libsrc/lwip202*]"
puts "XADAPTER_HDR: [glob -nocomplain $WS/bsp0/psu_cortexa53_0/include/netif/xadapter.h]"
set elf [glob -nocomplain $WS/net_v_app/Debug/*.elf]
if {[llength $elf] > 0} {
    foreach e $elf { puts "APP_ELF_OK: $e size=[file size $e] mtime=[clock format [file mtime $e] -format %H:%M:%S]" }
} else {
    puts "APP_ELF_MISSING"
}
puts "FIX_LWIP_DONE"
