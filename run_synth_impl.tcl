# run_synth_impl.tcl — 阶段 4：综合 + 实现 + 报告（Vivado 2018.3 批处理，非工程模式）
# 用法：vivado -mode batch -source run_synth_impl.tcl -log vivado_synth.log
# 权重存储：行为级数组 + ram_style=ultra、无 initial → 推断 URAM288（已实验证实）；
# 权重由 PS 启动时经加载口写入（URAM 硅片不支持 bitstream 初始化）。
set SRC C:/yshlearn/FPGA_learn/RL_project
set RPT $SRC/reports
file mkdir $RPT

# 读 RTL（rtl/ 下模块；tb 在 rtl/tb/ 子目录，不会被卷入）
read_verilog [glob $SRC/rtl/*.v]
read_xdc $SRC/constraints/timing.xdc

# 综合（out_of_context：这是将来嵌进 BD 的 PL 核，400+ 个顶层端口不做引脚布局）
synth_design -mode out_of_context -top net_v_top -part xczu7ev-ffvc1156-2-e
report_utilization -file $RPT/util_synth.txt
puts "SYNTH_DONE"

# 实现
opt_design
place_design
route_design
report_utilization -file $RPT/util_impl.txt
report_timing_summary -file $RPT/timing_summary.txt
puts "IMPL_DONE"
exit 0
