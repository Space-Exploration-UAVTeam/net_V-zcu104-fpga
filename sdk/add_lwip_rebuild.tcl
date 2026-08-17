# add_lwip_rebuild.tcl — BSP 加 lwip202 + 重导源码 + 全量重编（SDK 2018.3）
#
# 前置：create_sdk_ws.tcl 已建好 ws（hw0/bsp0/net_v_app/fsbl/pmufw）。
# 输入：$ROOT/src/ 下的 main.c（新版带 UDP）、platform_zynqmp.c、
#       platform.h、platform_config.h、weights.h
# 产物：ws/net_v_app/Debug/net_v_app.elf（含 lwIP）

set ROOT C:/yshlearn/FPGA_learn/RL_project_sdk
set WS   $ROOT/ws

setws $WS

# --- BSP 加 lwIP 库；DHCP 关（固定 IP 由 app 侧 netif_add 设置）---
setlib -bsp bsp0 -lib lwip202
if {[catch {configbsp -bsp bsp0 -lib lwip202 lwip_dhcp false} e]} {
    puts "CFG_NOTE lwip_dhcp: $e"
}
if {[catch {configbsp -bsp bsp0 -lib lwip202 dhcp_does_arp_check false} e]} {
    puts "CFG_NOTE dhcp_arp: $e"
}
puts "LWIP_LIBS: [getlibs -bsp bsp0]"

# --- 重导 app 源码（main.c 变了 + 新增平台/lwIP 文件）---
foreach f [glob -nocomplain $WS/net_v_app/src/*.c $WS/net_v_app/src/*.h] {
    file delete -force $f
}
importsources -name net_v_app -path $ROOT/src
puts "APP_SRCS: [glob -nocomplain $WS/net_v_app/src/*]"

# --- 全量重编（bsp 变了会触发 app 重链）---
if {[catch {projects -build} e]} {
    puts "BUILD_ERROR: $e"
}
foreach p {net_v_app fsbl pmufw} {
    set elf [glob -nocomplain $WS/$p/Debug/*.elf]
    if {[llength $elf] > 0} {
        foreach e $elf { puts "ELF_OK_$p: $e size=[file size $e]" }
    } else {
        puts "ELF_MISSING_$p"
    }
}
puts "REBUILD_LWIP_DONE"
