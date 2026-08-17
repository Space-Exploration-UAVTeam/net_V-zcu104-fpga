# copy_hex.tcl — 综合 run 的 TCL.PRE hook（在 run 目录里、 synth_design 之前执行）
#
# 为什么需要：bias_rom.v / elu_lut.v 的 initial $readmemh("data/hex/...")
# 在综合期也生效（无 SYNTHESIS 宏保护），launch_runs 子进程 CWD=run 目录，
# 相对路径找不到会把 ROM 静默清零。此 hook 把 hex 摆进 run 目录。
# weight_rom 综合期跳过初始化（PS 启动时经 AXI 加载），一并复制无害。

file mkdir data/hex
foreach f {bias_all.hex elu_lut.hex weights_all.hex} {
    file copy -force C:/yshlearn/FPGA_learn/RL_project/data/hex/$f data/hex/$f
}
puts "HEX_STAGED: [glob data/hex/*]"
