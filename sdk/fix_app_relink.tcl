# fix_app_relink.tcl — 重建 net_v_app 工程让链接行带上 -llwip4（SDK 2018.3）
#
# 背景：bsp0 加 lwip202 后 BSP 已产出 liblwip4.a，但既有 app 工程的
#       链接参数是建工程时生成的（没有 lwIP 库），改不动 → 删工程重建
#       （此时 BSP 已含 lwIP，新建 app 自动继承 -llwip4 链接组）。
#       源码安全：真本在 $ROOT/src/，工程里的是 importsources 的副本。

set ROOT C:/yshlearn/FPGA_learn/RL_project_sdk
set WS   $ROOT/ws

setws $WS

if {[catch {deleteprojects -name net_v_app} e]} {
    puts "DEL_NOTE: $e"
}
# 物理清残留（deleteprojects 只删元数据时）
if {[file isdirectory $WS/net_v_app]} {
    file delete -force $WS/net_v_app
    puts "DIR_REMOVED"
}

createapp -name net_v_app -app {Empty Application} -hwproject hw0 \
    -bsp bsp0 -proc psu_cortexa53_0 -lang c
foreach f [glob -nocomplain $WS/net_v_app/src/*.c $WS/net_v_app/src/*.h] {
    file delete -force $f
}
importsources -name net_v_app -path $ROOT/src

if {[catch {projects -build -type app -name net_v_app} e]} {
    puts "APP_BUILD_ERROR: $e"
}
set elf [glob -nocomplain $WS/net_v_app/Debug/*.elf]
if {[llength $elf] > 0} {
    foreach e $elf {
        puts "APP_ELF_OK: $e size=[file size $e] mtime=[clock format [file mtime $e] -format {%m-%d %H:%M:%S}]"
    }
} else {
    puts "APP_ELF_MISSING"
}
puts "FIX_RELINK_DONE"
