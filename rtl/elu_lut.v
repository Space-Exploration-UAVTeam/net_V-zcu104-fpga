`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// elu_lut.v — ELU 激活的 LUT + 线性插值（纯组合逻辑，全整数运算）
//
// 功能：y = ELU(z)，α=1。输入 z 是某层激活 Q 格式的 int18 定点整数
//       （小数位 f = 该层 act_frac），输出同位宽同 frac。
//       语义逐字照抄 docs/fixed_point_spec.md §4（golden_model/elu_lut.py
//       的硬件镜像），三条支路：
//         正支直通：z ≥ 0        → y = z
//         负支钳位：z ≤ -8·2^f   → y = -2^f（即 -1.0；边界 -8 也走这里，
//                                  与表项 T[0] 差 ≤1LSB，是有意的规格）
//         负支查表：-8·2^f < z < 0 → 查表 + 低位线性插值：
//           u    = clamp(z + 8·2^f, 0, 8·2^f - 1)
//           idx  = u >> IB            （高 f+3-IB 位 = 表地址）
//           frac = u & (2^IB - 1)     （低 IB 位 = 档内位置）
//           y    = T[idx] + ((T[idx+1] - T[idx])·frac + 2^(IB-1)) >> IB
//         IB=0 时 y = T[idx]（精确查表，无插值）
//         插值右移用规则②（先加半 LSB 再算术右移，与 CUT_POS 同一规则）
//
// ROM：5 张去重表共 1157 项 int16（f=12/10/7/5 各 257 项，f=4 为 129 项；
//       layer_04 与 layer_06 同为 f=5，共享一张表），与 golden model 的
//       build_elu_lut 同源（scripts/gen_hex.py 导出并回读自检）：
//         f=12 → 基址 0     f=10 → 基址 257   f=7 → 基址 514
//         f=5  → 基址 771   f=4  → 基址 1028
//
// 用法：本模块是纯组合逻辑；调用方（fc_engine）在其输出端寄一拍。
//       每个神经元 32 拍才用 1 次，全网时分复用这一个单元。
//////////////////////////////////////////////////////////////////////////////

module elu_lut #(
    parameter HEX_FILE = "data/hex/elu_lut.hex",
    parameter DEPTH    = 1157          // 257×4 + 129
)(
    input  wire signed [17:0] z,        // 输入（饱和后的激活，int18）
    input  wire [10:0]        rom_base, // 该层 LUT 表基址（≤1028）
    input  wire [3:0]         fbits,    // 该层 act_frac f（4..12）
    input  wire [3:0]         ibits,    // 该层插值位数 IB（0..7）
    output reg  signed [17:0] y         // 输出（同 Q 格式 int18）
);

    // 表项 ROM（int16 补码），异步读——小表，综合走分布式 ROM/寄存器
    reg signed [15:0] mem [0:DEPTH-1];
    initial begin
        $readmemh(HEX_FILE, mem);
    end

    // 中间量（全整数运算，位宽留足余量）
    reg signed [19:0] offset;      // 8·2^f ≤ 32768
    reg signed [19:0] u;           // z 偏移后 clamp 到 [0, 8·2^f)
    reg        [8:0]  idx;         // 表地址（≤255）
    reg        [6:0]  frac;        // 档内位置（IB ≤ 7）
    reg signed [15:0] t0, t1;      // 相邻两表项
    reg signed [16:0] dt;          // t1 - t0（ELU 单调增，实际 ≥ 0）
    reg signed [31:0] interp;      // dt·frac + 半 LSB
    reg signed [31:0] lut_ext;     // t0 + (interp >>> IB)

    always @(*) begin
        offset = 20'sd8 <<< fbits;

        // u = clamp(z + offset, 0, offset-1)；z 先符号扩展到 20bit
        u = {{2{z[17]}}, z} + offset;
        if (u < 20'sd0)
            u = 20'sd0;
        else if (u > offset - 20'sd1)
            u = offset - 20'sd1;

        idx  = u[19:0] >>> ibits;                 // u ≥ 0，算术/逻辑右移等价
        frac = u[6:0] & ((8'd1 <<< ibits) - 8'd1);  // 低 IB 位 = 档内位置

        t0 = mem[rom_base + {2'b0, idx}];
        t1 = mem[rom_base + {2'b0, idx} + 11'd1];
        dt = {t1[15], t1} - {t0[15], t0};

        // 插值分子（ibits=0 时不用，但计算无害——右移 0 位不取它）
        interp = dt * $signed({2'b0, frac});
        if (ibits == 4'd0)
            lut_ext = {{16{t0[15]}}, t0};                       // 精确查表
        else
            lut_ext = {{16{t0[15]}}, t0}
                      + ((interp + (32'sd1 <<< (ibits - 4'd1))) >>> ibits);

        // 三条支路选择（注意：判支路用原始 z，不是 clamp 后的 u）
        if (z[17] == 1'b0)                               // 正支直通
            y = z;
        else if ({{2{z[17]}}, z} <= -offset)             // 负支钳到 -1.0
            y = -(18'sd1 <<< fbits);
        else                                             // 负支查表+插值
            y = lut_ext[17:0];
    end

endmodule
