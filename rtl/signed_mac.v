`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// signed_mac.v — 有符号乘加器（MAC）
//
// 功能：每个时钟拍输入一对 (a, w)，输出乘积 a*w，并累加到 acc。
//       acc = a0*w0 + a1*w1 + a2*w2 + ...
//
/*引脚      方向    作用
clk, rst   输入    时钟和复位
a, w       输入    这一拍要乘的两个数（有符号 8 位）
acc_en     输入    =1 时本拍累加，=0 时保持
acc_clear  输入    =1 时清零累加器
acc        输出    累加结果（20 位）
*/
// 修复记录（2026-08-07）：
//   - 把 ACC_W 从 module body 的 localparam 移到 #() 参数列表，
//     因为 Vivado 2018.3 不支持 body 里的 localparam 用于端口宽度声明。
//////////////////////////////////////////////////////////////////////////////

/*
工作原理（每拍）：
1. prod = a * w（第 28 行，组合逻辑，始终在算）
2. 如果 acc_clear=1 → acc 清零（第 33 行）
3. 如果 acc_en=1 → acc 加上 prod（第 35 行）
4. 否则保持不动
用的时候：连送 N 拍 (a_i, w_i)、acc_en 一直拉高，N 拍后 acc 里就是累加结果。换一组新数据时拉一拍 acc_clear 清零。
关键设计点：累加器比数据宽——8 位输入，累加器 20 位。因为 N 个数加起来可能超过 8 位，必须预留空间（第 14 行 ACC_W=20）。
*/

module signed_mac #(
    parameter DATA_W = 8,         // 输入数据位宽
    parameter ACC_W  = 20         // 累加器位宽 = 2*DATA_W + log2裕量
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire signed [DATA_W-1:0] a,
    input  wire signed [DATA_W-1:0] w,
    input  wire                     acc_en,
    input  wire                     acc_clear,
    output reg  signed [ACC_W-1:0]  acc
);

    wire signed [2*DATA_W-1:0] prod;
    assign prod = a * w;

    always @(posedge clk) begin
        if (rst) begin
            acc <= {ACC_W{1'b0}};
        end else if (acc_clear) begin
            acc <= {ACC_W{1'b0}};
        end else if (acc_en) begin
            acc <= acc + prod;
        end
    end

endmodule
