# create_sdk_ws.tcl — xsct 建 SDK 工作区并编译（Vivado SDK 2018.3）
#
# 用法：xsct.bat create_sdk_ws.tcl（CWD 任意）
# 输入：C:/yshlearn/FPGA_learn/RL_project_bd/sdk/net_v_bd.hdf（含 bitstream）
#       C:/yshlearn/FPGA_learn/RL_project_sdk/src/{main.c, weights.h}
# 产物：C:/yshlearn/FPGA_learn/RL_project_sdk/ws/net_v_app/Debug/net_v_app.elf
#       （可选 fsbl.elf / pmufw.elf，失败只记录不影响 app 验收）

set ROOT C:/yshlearn/FPGA_learn/RL_project_sdk
set WS   $ROOT/ws
set HDF  C:/yshlearn/FPGA_learn/RL_project_bd/sdk/net_v_bd.hdf

setws $WS

createhw -name hw0 -hwspec $HDF

# A53 core0 standalone BSP（A53 默认 64bit 工具链）
createbsp -name bsp0 -hwproject hw0 -proc psu_cortexa53_0 -os standalone

# 空应用模板建 app，然后清掉模板源文件（保留 lscript.ld），导入我们的
createapp -name net_v_app -app {Empty Application} -hwproject hw0 \
    -bsp bsp0 -proc psu_cortexa53_0 -lang c
foreach f [glob -nocomplain $WS/net_v_app/src/*.c $WS/net_v_app/src/*.h] {
    file delete -force $f
}
importsources -name net_v_app -path $ROOT/src

# 先 BSP 后 app（build 失败也继续走到打印 elf 状态，便于定位）
if {[catch {projects -build -type bsp -name bsp0} e]} {
    puts "BSP_BUILD_ERROR: $e"
}
if {[catch {projects -build -type app -name net_v_app} e]} {
    puts "APP_BUILD_ERROR: $e"
}

set elf [glob -nocomplain $WS/net_v_app/Debug/*.elf]
if {[llength $elf] > 0} {
    foreach e $elf { puts "APP_ELF_OK: $e size=[file size $e]" }
} else {
    puts "APP_ELF_MISSING"
}

# ---------------- 可选：FSBL / PMUFW（板子启动用，不参与本次验收）---------
puts "APP_TEMPLATES: [lsort [repo -apps]]"
if {[catch {
    createapp -name fsbl -app {Zynq MP FSBL} -hwproject hw0 -proc psu_cortexa53_0
    projects -build -type app -name fsbl
} e]} {
    puts "FSBL_SKIP: $e"
} else {
    puts "FSBL_ELF: [glob -nocomplain $WS/fsbl/Debug/*.elf]"
}
if {[catch {
    createapp -name pmufw -app {ZynqMP PMU Firmware} -hwproject hw0 -proc psu_pmu_0
    projects -build -type app -name pmufw
} e]} {
    puts "PMUFW_SKIP: $e"
} else {
    puts "PMUFW_ELF: [glob -nocomplain $WS/pmufw/Debug/*.elf]"
}

puts "SDK_WS_DONE"
