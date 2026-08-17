# build_bd.tcl — net_v_axi + ZynqMP PS 的 Block Design 搭建（Vivado 2018.3）
#
# 前置：package_ip.tcl 已成功跑完（ip_repo 里有 net_v_axi_1.0）。
# 本脚本只搭 BD + validate + 生成输出产品；综合/实现见 run_impl.tcl。
# 板文件缺失时直接 FATAL 退出（不手配 PS/DDR）。

set ROOT   C:/yshlearn/FPGA_learn/RL_project_bd
set PROJ   $ROOT/bd_proj
# ipx::package_project -root_dir 直接是 IP 目录本身，仓库取其父目录
set REPO   C:/yshlearn/FPGA_learn/RL_project_ip
set PART   xczu7ev-ffvc1156-2-e

# --- 板文件检查 ---
set bp_all [get_board_parts -quiet *zcu104*]
if {[llength $bp_all] == 0} {
    puts "FATAL_NO_ZCU104_BOARD_PART"
    exit 1
}
set bp [lindex [lsort $bp_all] end]
puts "USING_BOARD_PART: $bp"

create_project net_v_bd $PROJ -part $PART -force
set_property board_part $bp [current_project]
set_property ip_repo_paths $REPO [current_project]
update_ip_catalog
puts "IPDEF_NET_V: [get_ipdefs -quiet ysh:net_v:net_v_axi:*]"

create_bd_design design_1

# --- PS + 板级预设（DDR4/时钟/外设由预设配好）---
# 2018.3 的 zynq_ultra_ps_e 规则必须带 -config {apply_board_preset "1"}，
# 空 config 会报 key "CONFIG" not known in dictionary
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

# --- 开 M_AXI_HPM0_FPD（32bit 主机口），确保 PL0=100MHz ---
set ps [get_bd_cells zynq_ultra_ps_e_0]
set allprops [list_property $ps]
foreach {k v} {
    CONFIG.PSU__USE__M_AXI_GP0                    1
    CONFIG.PSU__MAXIGP0__DATA_WIDTH               32
    CONFIG.PSU__FPGA_PL0_ENABLE                   1
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ    100
} {
    if {[lsearch -exact $allprops $k] >= 0} {
        set_property $k $v $ps
        puts "SET_PROP $k = $v"
    } else {
        puts "MISS_PROP $k"
    }
}
puts "FCLK_CANDIDATES: [lsearch -all -inline -glob $allprops *PL0_REF_CTRL*]"

# --- 我们的 IP ---
create_bd_cell -type ip -vlnv ysh:net_v:net_v_axi:1.0 net_v_axi_0

# --- AXI 自动化：HPM0_FPD 做主机，自动插互联 + proc_sys_reset + 时钟复位 ---
# 2018.3 的 axi4 规则 config 键名版本间有差异，逐级兜底
set axi_done 0
if {[catch {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
        {Master "/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD" Clk "Auto" } \
        [get_bd_intf_pins net_v_axi_0/s_axi]
} err]} {
    puts "AUTO_AXI4_CFG1_FAILED: $err"
} else {
    set axi_done 1
}
if {!$axi_done} {
    if {[catch {
        apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
            { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
              Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} \
              ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
            [get_bd_intf_pins net_v_axi_0/s_axi]
    } err]} {
        puts "AUTO_AXI4_CFG2_FAILED: $err"
        apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
            [get_bd_intf_pins net_v_axi_0/s_axi]
    }
}

# --- ZCU104 预设还开了 HPM1_FPD，其 aclk 空接会报 DRC：接到 pl_clk0 ---
if {[llength [get_bd_pins -quiet zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]] > 0} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk] \
        [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
    puts "HPM1_ACLK_CONNECTED"
}

# --- 连线自检（打进 log）---
puts "BD_CELLS: [get_bd_cells]"
foreach pin {
    zynq_ultra_ps_e_0/pl_clk0
    zynq_ultra_ps_e_0/pl_resetn0
    zynq_ultra_ps_e_0/maxihpm0_fpd_aclk
    net_v_axi_0/s_axi_aclk
    net_v_axi_0/s_axi_aresetn
} {
    puts "NETOF $pin = [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin]]"
}
if {[llength [get_bd_cells -quiet proc_sys_reset_0]] > 0} {
    foreach pin {
        proc_sys_reset_0/slowest_sync_clk
        proc_sys_reset_0/ext_reset_in
        proc_sys_reset_0/peripheral_aresetn
        proc_sys_reset_0/interconnect_aresetn
    } {
        puts "NETOF $pin = [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin]]"
    }
} else {
    puts "WARN_NO_PROC_SYS_RESET"
}

# --- 地址分配 ---
assign_bd_address
foreach seg [get_bd_addr_segs -quiet] {
    puts "ADDR_SEG $seg offset=[get_property offset $seg] range=[get_property range $seg]"
}

validate_bd_design
save_bd_design

# --- 输出产品 + 顶层 wrapper ---
generate_target all [get_files design_1.bd]
set wrap [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrap
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "WRAPPER: $wrap"

write_bd_tcl -force $ROOT/design_1_dump.tcl
puts "BD_BUILD_DONE"
