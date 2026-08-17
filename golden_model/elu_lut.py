"""
elu_lut.py — ELU 的 LUT + 线性插值硬件实现（bit-true）
======================================================

【数学定义】ELU(α=1)：y = x (x≥0)；y = e^x - 1 (x<0)，负向渐近 -1。

【硬件方案】（规格定死，RTL 逐字照抄；详见 docs/fixed_point_spec.md）
- 输入 z 是该层激活 Q 格式的 int16 定点整数（小数位 f = 该层 act_frac）。
- 正支直通：z ≥ 0 → y = z。
- 负支查表：覆盖 [-8, 0)。z ≤ -8·2^f → y = -2^f（即 -1.0，钳位）。
- 表：在 [-8, 0) 上均匀取 K 档（K+1 个表项，含 x=0 端点），
  表项 T[i] = quantize_to(elu(x_i), f, 16)，x_i = -8 + i·(8/K)。
  全部 int16 存 ROM。
- 地址与插值（全整数运算）：
    u        = z + 8·2^f            # 偏移到 [0, 8·2^f)
    idx      = u >> INTERP_BITS     # 高位做表地址
    frac     = u 的低 INTERP_BITS 位 # 档内位置
    y        = T[idx] + ((T[idx+1]-T[idx])·frac + 2^(INTERP_BITS-1)) >> INTERP_BITS
  插值右移的舍入规则与 CUT_POS 相同（先加半 LSB 再算术右移，规则②）。
- 档数自适应：K = min(N_SEG, 8·2^f)。当 8·2^f ≤ N_SEG（即 f ≤ log2(N_SEG)-3），
  每个可表示的负输入都有独立表项，INTERP_BITS=0，无需插值（精确查表）。

【误差】表项量化误差 ≤ 2^-(f+1)；插值误差对 ELU（二阶导 e^x≤1）
≤ (8/K)²/8，K=256 时 ≤ 1.5e-5，远小于各层 half-LSB。
"""

import numpy as np
from . import quantize as q

# 默认规格（与 config.ELU_LUT_N / ELU_NEG_RANGE 对应，RTL 照抄）
DEFAULT_N_SEG = 256      # 最大档位数
DEFAULT_NEG_RANGE = 8    # 负支覆盖 [-8, 0)


def build_elu_lut(frac_bits, n_segments=DEFAULT_N_SEG, neg_range=DEFAULT_NEG_RANGE):
    """生成某一层激活 Q 格式对应的 ELU LUT。

    参数:
        frac_bits  : 该层激活的小数位 f
        n_segments : 最大档位数（ROM 深度上限）
        neg_range  : 负支覆盖区间长度（固定 8）
    返回:
        dict: {"table": (K+1,) int64 表项, "frac_bits": f,
               "offset": 8·2^f, "interp_bits": 档内插值位数, "n_entries": K+1}
    """
    f = int(frac_bits)
    offset = neg_range * (1 << f)              # 负支定点码数 M = 8·2^f
    k = min(int(n_segments), offset)           # 实际档数 K
    interp_bits = (offset // k).bit_length() - 1   # log2(M/K)，M、K 都是 2 的幂
    assert (1 << interp_bits) * k == offset, "档数必须是 2 的幂"

    xs = -neg_range + np.arange(k + 1) * (neg_range / k)   # x_0..x_K（含 0）
    table = q.quantize_to(np.where(xs >= 0, xs, np.exp(xs) - 1.0), f, bits=16)

    return {
        "table": table,
        "frac_bits": f,
        "offset": offset,
        "interp_bits": interp_bits,
        "n_entries": k + 1,
    }


def elu_lut_apply(z, lut):
    """对定点整数 z（int16 值域）做 LUT ELU，返回同 Q 格式的定点整数。

    支持标量或任意形状数组（向量化）。全程整数运算，与 RTL 一致。
    """
    z = np.asarray(z, dtype=np.int64)
    f = lut["frac_bits"]
    offset = lut["offset"]
    ib = lut["interp_bits"]
    T = lut["table"]

    y = z.copy()
    neg = z < 0
    if not np.any(neg):
        return y

    zn = z[neg]
    u = np.clip(zn + offset, 0, offset - 1)    # [0, offset)，越界先钳（下面统一处理）
    idx = u >> ib
    frac = u - (idx << ib)                     # 档内低位
    dt = T[idx + 1] - T[idx]
    if ib > 0:
        val = T[idx] + ((dt * frac + (1 << (ib - 1))) >> ib)
    else:
        val = T[idx]                           # 精确查表，无插值

    # z ≤ -8·2^f 钳到 -1.0（=-2^f）。注意 u<0 的输入先按钳位处理。
    val = np.where(zn <= -offset, -(1 << f), val)
    y[neg] = val
    return y
