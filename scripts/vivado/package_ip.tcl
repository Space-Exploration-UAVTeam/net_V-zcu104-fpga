# package_ip.tcl — 把 net_v_axi 打包成 AXI4-Lite IP（Vivado 2018.3 批处理）
#
# 启动要求：vivado 进程 CWD = C:/yshlearn/FPGA_learn/RL_project
#   （bias_rom/elu_lut 综合期 $readmemh 用相对路径 data/hex/...，本次 lint
#     综合直接在进程 CWD 里跑，顺路验证 ROM 初始化能找到 hex）
#
# 产物：C:/yshlearn/FPGA_learn/RL_project_ip/ip_repo/net_v_axi_1.0/
#
# 注意：2018.3 的 ipx::package_project 会自动推断 s_axi/s_axi_aclk/
#   s_axi_aresetn 接口（含 POLARITY/ASSOCIATED_* 参数），所以下面全部
#   按“存在则跳过/修正”写法，不重复 infer。

set SRC   C:/yshlearn/FPGA_learn/RL_project/rtl
set ROOT  C:/yshlearn/FPGA_learn/RL_project_ip
set PROJ  $ROOT/pkg_proj
set REPO  $ROOT/ip_repo
set PART  xczu7ev-ffvc1156-2-e

create_project net_v_axi_pkg $PROJ -part $PART -force

puts "PROBE_BOARD_PARTS: [get_board_parts]"
puts "PROBE_ZYNQ: [get_ipdefs -quiet xilinx.com:ip:zynq_ultra_ps_e:*]"

add_files -norecurse [list \
    $SRC/weight_rom.v \
    $SRC/bias_rom.v \
    $SRC/elu_lut.v \
    $SRC/fc_engine.v \
    $SRC/net_v_top.v \
    $SRC/axi/net_v_axi.v]
set_property top net_v_axi [current_fileset]
update_compile_order -fileset sources_1

# --- 综合 lint（过即可；weight_rom 无初始化报 0 警告属正常）---
synth_design -top net_v_axi -part $PART
puts "LINT_SYNTH_OK"

# --- 打包到 ip_repo（自动推断总线接口）---
ipx::package_project -root_dir $REPO -vendor ysh -library net_v \
    -taxonomy /UserIP -import_files -force
set core [ipx::current_core]
set_property name net_v_axi $core
set_property display_name net_v_axi $core
set_property description {net_V FCNN AXI4-Lite wrapper for ZCU104} $core
set_property core_revision 1 $core
set_property supported_families {zynquplus Pre-Production} $core

# --- s_axi：确保存在，并标成 AXI4LITE ---
set busif [ipx::get_bus_interfaces -quiet s_axi -of_objects $core]
if {[llength $busif] == 0} {
    ipx::infer_bus_interface s_axi xilinx.com:interface:aximm_rtl:1.0 $core
    set busif [ipx::get_bus_interfaces s_axi -of_objects $core]
    puts "SAXI_INFERRED_MANUALLY"
}
set pp [ipx::get_bus_parameters -quiet PROTOCOL -of_objects $busif]
if {[llength $pp] == 0} {
    ipx::add_bus_parameter PROTOCOL $busif
    set pp [ipx::get_bus_parameters -quiet PROTOCOL -of_objects $busif]
}
set_property value AXI4LITE $pp

# --- 时钟/复位接口：缺则补推断；关联/极性缺则补 ---
if {[llength [ipx::get_bus_interfaces -quiet s_axi_aclk -of_objects $core]] == 0} {
    ipx::infer_bus_interface s_axi_aclk xilinx.com:signal:clock_rtl:1.0 $core
}
if {[llength [ipx::get_bus_interfaces -quiet s_axi_aresetn -of_objects $core]] == 0} {
    ipx::infer_bus_interface s_axi_aresetn xilinx.com:signal:reset_rtl:1.0 $core
}
set clkif [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
if {[llength [ipx::get_bus_parameters -quiet ASSOCIATED_BUSIF -of_objects $clkif]] == 0} {
    ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
}
set rstif [ipx::get_bus_interfaces s_axi_aresetn -of_objects $core]
set pol [ipx::get_bus_parameters -quiet POLARITY -of_objects $rstif]
if {[llength $pol] == 0} {
    ipx::add_bus_parameter POLARITY $rstif
    set pol [ipx::get_bus_parameters -quiet POLARITY -of_objects $rstif]
}
set_property value ACTIVE_LOW $pol

# --- 地址映射（memory map + 4K 地址块；已存在则只打印）---
set mm_all [ipx::get_memory_maps -quiet -of_objects $core]
puts "MEMMAPS_AFTER_PACKAGE: $mm_all"
if {[llength $mm_all] == 0} {
    ipx::add_memory_map s_axi $core
    set mm [ipx::get_memory_maps s_axi -of_objects $core]
    ipx::add_address_block reg0 $mm
    set ab [ipx::get_address_blocks reg0 -of_objects $mm]
    set_property range 4K $ab
    set_property usage register $ab
    set_property access read-write $ab
    set_property width 32 $ab
    set_property slave_memory_map_ref s_axi $busif
    puts "MEMMAP_CREATED_MANUALLY"
}
foreach m [ipx::get_memory_maps -quiet -of_objects $core] {
    foreach ab [ipx::get_address_blocks -quiet -of_objects $m] {
        catch { puts "ADDR_BLOCK $ab range=[get_property range $ab] usage=[get_property usage $ab] width=[get_property width $ab]" }
    }
}
puts "SLAVE_MM_REF: [get_property -quiet slave_memory_map_ref $busif]"
puts "FINAL_BUSIFS: [ipx::get_bus_interfaces -of_objects $core]"

ipx::save_core $core
puts "PACKAGE_DONE: $REPO"
