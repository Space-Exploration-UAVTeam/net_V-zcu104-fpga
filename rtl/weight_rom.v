`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// weight_rom.v — 全网权重存储（256bit 字 = 16 条 lane 的 int16）
//
// 功能：存全部 7 层的量化权重（int16，逐层 w_frac 见 fixed_point_spec.md §2），
//       同步读（1 拍延迟），每拍给 16 路乘法器供一个字。
//
// 打包格式（与 scripts/gen_hex.py 一致，每拍读一个字供 16 lane）：
//   - 一个字 256bit：bit[16k+15:16k] = lane k（k=0..15），
//     lane k 对应输入元素 a[16*t + k]（t = 组号）
//   - 地址 = w_base[层] + 神经元号 j × NG + 组号 t（"输出神经元连续"）
//   - layer_01 只有 7 个有效输入：lane 7..15 的权重在打包时已补 0
//
// 各层基址 w_base（由 gen_hex.py 生成并自检，fc_engine.v 参数表照抄）：
//   layer_01=0  layer_02=512  layer_03=16896  layer_04=33280
//   layer_05=49664  layer_06=66048  layer_07=82432  总字数 82464
//
// 实现方式（2026-08-13 定稿，经 Vivado 2018.3 实验证实）：
//   URAM 硅片不支持 bitstream 初始化（blk_mem_gen 禁 coe、XPM/行为级带
//   $readmemh 会静默回退 BRAM/分布式 RAM——均实测）。因此：
//     - 综合：行为级数组 + ram_style=ultra + 无 initial → 推断 84 块 URAM288
//     - 权重由 PS 在启动后经加载口（wr_*）写入一次（AXI 外壳在后续阶段接）
//     - 仿真：`ifndef SYNTHESIS 下保留 $readmemh 初始化（iverilog/XSim 验证
//       路径不变，全部既有验证结论有效）
//////////////////////////////////////////////////////////////////////////////

module weight_rom #(
    parameter HEX_FILE = "data/hex/weights_all.hex",
    parameter DEPTH    = 82464,        // 总字数（7 层合计）
    parameter ADDR_W   = 17            // 2^17 = 131072 ≥ 82464
)(
    input  wire               clk,
    input  wire [ADDR_W-1:0]  addr,    // 读地址（本拍给，下一拍出数据）
    output reg  [255:0]       q,       // 权重字（16 lane × int16）
    // PS 加载口（启动阶段写权重；推理时 wr_en 恒 0）
    input  wire               wr_en,
    input  wire [ADDR_W-1:0]  wr_addr,
    input  wire [255:0]       wr_data
);

    (* ram_style = "ultra" *) reg [255:0] mem [0:DEPTH-1];

`ifndef SYNTHESIS
    // 仅仿真：预载权重（综合时此块被跳过，否则 URAM 推断会静默回退）
    initial begin
        $readmemh(HEX_FILE, mem);
    end
`endif

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        q <= mem[addr];                 // read-first；推理期间 wr_en=0，无冲突
    end

endmodule
