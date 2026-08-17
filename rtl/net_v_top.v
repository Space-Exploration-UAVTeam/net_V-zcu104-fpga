`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_top.v — net_V 全网推理顶层（start/done 握手 + 7 个输入寄存器）
//
// 功能：7 维 Q6.10 int16 输入 → 7 层 FC 推理 → 40bit 累加器原值输出。
//       本阶段 testbench 直接驱动端口；AXI-Lite 外壳是后续阶段（此时
//       把 x_in_0..6 / start / done / result 映射成寄存器即可）。
//
// 握手：
//   1. 驱动 x_in_0..6，把 start 拉高一拍
//   2. 等 done == 1（单样本约 8.26 万拍）
//   3. 读 result（40bit 有符号，acc_frac7=20 刻度；PS 反量化 ΔV = result×2^-20）
//   done 保持到下一次 start；再次 start 前 result 保持有效。
//
// HEX 文件路径：默认相对 RL_project 根目录（仿真工作目录 = RL_project）。
// Vivado 工程里用时，把 data/hex/ 下 3 个 hex 加进 simulation sources
// （$readmemh 会按文件名在仿真运行目录找），或在这里改成绝对路径。
//////////////////////////////////////////////////////////////////////////////

module net_v_top #(
    parameter W_HEX = "data/hex/weights_all.hex",
    parameter B_HEX = "data/hex/bias_all.hex",
    parameter E_HEX = "data/hex/elu_lut.hex"
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire signed [15:0] x_in_0,   // Q6.10 int16，PS 量化好送来的
    input  wire signed [15:0] x_in_1,
    input  wire signed [15:0] x_in_2,
    input  wire signed [15:0] x_in_3,
    input  wire signed [15:0] x_in_4,
    input  wire signed [15:0] x_in_5,
    input  wire signed [15:0] x_in_6,
    output wire signed [39:0] result,   // layer_07 累加器原值（40bit）
    output wire               done,
    // 权重加载口（PS 启动阶段经 AXI 外壳驱动；推理时 w_wr_en 恒 0）
    input  wire               w_wr_en,
    input  wire [16:0]        w_wr_addr,
    input  wire [255:0]       w_wr_data
);

    fc_engine #(
        .W_HEX(W_HEX),
        .B_HEX(B_HEX),
        .E_HEX(E_HEX)
    ) u_engine (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .x_in_0 (x_in_0),
        .x_in_1 (x_in_1),
        .x_in_2 (x_in_2),
        .x_in_3 (x_in_3),
        .x_in_4 (x_in_4),
        .x_in_5 (x_in_5),
        .x_in_6 (x_in_6),
        .result (result),
        .done   (done),
        .w_wr_en   (w_wr_en),
        .w_wr_addr (w_wr_addr),
        .w_wr_data (w_wr_data)
    );

endmodule
