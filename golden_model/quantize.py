"""
quantize.py — 定点量化工具
===========================

这是 golden model 与硬件之间唯一的"数值格式"桥梁。

【核心问题】
硬件里没有小数，只有整数。要表示 -1.2345 这样的数，用定点 Q 格式：
    x_fixed = round(x * 2^FRAC_W)   # x_fixed 是整数

【关键概念：数据位宽 ≠ 累加器位宽】
- DATA_W : 数据总位宽（权重/输入/输出各存 16 位），如 16
- FRAC_W : 小数位宽，决定缩放因子 2^FRAC_W 和小数精度
- INT_W  : 整数位宽 = DATA_W - FRAC_W，决定浮点能表示的范围
- 浮点范围 = [ -2^(INT_W-1), 2^(INT_W-1) ]
    INT_W=5 → [-16, 16]；INT_W=1 → [-1, 1]（Q1.15，适合归一化数据）
- 累加器位宽 ≠ 数据位宽：乘积占 2*DATA_W，加 log2(N) 累加增长位，
  硬件累加器约 2*DATA_W + clog2(最大输入数) 位（如 16位数据 → 41位）。
  累加器不提前饱和，只在每层输出量化回 DATA_W 时才饱和。

【量化三步】
1. 缩放  x * 2^FRAC_W
2. 舍入  round（默认四舍五入，硬件实现需一致）
3. 饱和  clamp 到 [q_min, q_max]

【当前状态】
- Q 格式：占位（INT_W=5, DATA_W=16），拿到真实权重后
  必须"统计每层输出的实际范围"来定 INT_W——这是设计定型的关键步骤
- 舍入方式：默认四舍五入（round-half-to-even），硬件实现需一致
- 溢出处理：默认饱和（clamp），硬件实现需一致

【重要】这里的量化规则必须和硬件 RTL 完全一致，
否则 Python golden 和 XSim 结果对不上。改任何规则时两边同步。
"""

import numpy as np

# 从 config 读格式（这样只改 config 一处即可）
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from config import model_config as cfg


def set_q_format(data_w=None, int_w=None):
    """动态修改 Q 格式（拿到权重后调用）。返回当前格式 dict。"""
    if data_w is not None:
        cfg.DATA_W = data_w
    if int_w is not None:
        cfg.INT_W = int_w
    cfg.FRAC_W = cfg.DATA_W - cfg.INT_W
    return get_q_format()


def get_q_format():
    """返回当前 Q 格式信息。"""
    return {
        "data_w": cfg.DATA_W,
        "int_w": cfg.INT_W,
        "frac_w": cfg.FRAC_W,
    }


def q_max():
    """定点能表示的最大整数（由 DATA_W 决定，与 INT_W 无关）。

    定点数底层就是一个 DATA_W 位的有符号整数，范围永远是
    [-2^(DATA_W-1), 2^(DATA_W-1)-1]。INT_W 只决定小数点的位置（缩放），
    不限制整数的范围。
    """
    return (1 << (cfg.DATA_W - 1)) - 1


def q_min():
    """定点能表示的最小整数。"""
    return -(1 << (cfg.DATA_W - 1))


def to_fixed(x, round_mode="round"):
    """浮点 → 定点整数。

    参数:
        x         : 标量或 numpy 数组（浮点）
        round_mode: "round"(四舍五入) 或 "trunc"(截断)
    返回:
        定点整数值（numpy 数组 dtype=int64）

    公式：x_fixed = round(x * 2^FRAC_W)，然后饱和到 [q_min, q_max]。
    """
    x = np.asarray(x, dtype=np.float64)
    scaled = x * (2 ** cfg.FRAC_W)

    if round_mode == "round":
        # 四舍五入（numpy 默认 half-to-even，与硬件实现需对齐）
        fixed = np.round(scaled)
    elif round_mode == "trunc":
        fixed = np.trunc(scaled)
    else:
        raise ValueError(f"不支持的舍入模式: {round_mode}")

    # 饱和（clamp）到定点范围
    fixed = np.clip(fixed, q_min(), q_max())

    return fixed.astype(np.int64)


def from_fixed(fixed):
    """定点整数 → 浮点（反向转换，用于验证）。"""
    return np.asarray(fixed, dtype=np.float64) / (2 ** cfg.FRAC_W)


def quantize_layer(W, b, round_mode="round"):
    """整层权重/偏置定点化，返回 (W_fixed, b_fixed)。

    用于把浮点权重转成硬件里存的整数，供生成 .mif 或 Verilog 参数用。
    """
    W_fixed = to_fixed(W, round_mode)
    b_fixed = to_fixed(b, round_mode)
    return W_fixed, b_fixed


def saturating_accumulate(acc, term):
    """饱和累加：acc + term，溢出时 clamp。

    用于模拟硬件累加器的饱和行为（不是普通 Python 加法）。
    参数是定点整数。
    """
    return np.clip(np.asarray(acc, dtype=np.int64) + np.asarray(term, dtype=np.int64),
                   q_min(), q_max())


# ---------------------------------------------------------------------------
# 以下为阶段 2 的 bit-true 定点原语（语义 = RTL 语义，RTL 逐字照抄）
# ---------------------------------------------------------------------------
#
# 【舍入规则（定死，两处不同，勿混用）】
#   ① 离线/PS 侧浮点→定点（quantize_to）：round-half-away-from-zero
#      （|x| 加 0.5 后向零方向... 即 sign(x)*floor(|x|+0.5)，"四舍五入到远离零"）。
#      用于：权重量化（烧 ROM）、bias 量化（烧 ROM）、PS 归一化输入量化。
#   ② PL 侧定点再量化（round_shift，CUT_POS 右移）：先加 1<<(CUT_POS-1)
#      再算术右移，等价 round-half-toward-+∞（负数的 .5 向 +∞ 进）。
#      这是硬件移位器的天然行为，ELU LUT 插值也用同一规则。
# 【饱和规则】clamp 到目标位宽的有符号范围。
# 【累加器】40bit 有符号，Python 侧用 int64 模拟，累加中途不饱和，
#   只在再量化（round_shift + saturate_bits）时钳到 int16。

ACC_BITS = 40                       # 累加器位宽（硬件定死）
ACC_MAX = (1 << (ACC_BITS - 1)) - 1
ACC_MIN = -(1 << (ACC_BITS - 1))


def quantize_to(x, frac_bits, bits=16):
    """浮点 → 定点整数（离线/PS 侧，舍入规则①）。

    参数:
        x        : 浮点标量或数组
        frac_bits: 小数位数（Q 格式的 n）
        bits     : 目标位宽（默认 int16）
    返回:
        int64 数组（值域在 bits 位有符号范围内）

    公式：v = sign(x*2^f) * floor(|x*2^f| + 0.5)，再 clamp 到 bits 位范围。
    """
    s = np.asarray(x, dtype=np.float64) * (2.0 ** frac_bits)
    v = np.sign(s) * np.floor(np.abs(s) + 0.5)   # round-half-away-from-zero
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return np.clip(v, lo, hi).astype(np.int64)


def round_shift(acc, cut_pos):
    """定点再量化右移（PL 侧，舍入规则②）= RTL 的 CUT_POS 截位。

    先加 1<<(cut_pos-1)（半 LSB）再做算术右移，实现四舍五入
    （round-half-toward-+∞）。cut_pos=0 时原样返回。
    输入/输出都是 int64（值域含义由调用方的 Q 格式决定）。
    """
    acc = np.asarray(acc, dtype=np.int64)
    if cut_pos <= 0:
        return acc
    return (acc + (1 << (cut_pos - 1))) >> cut_pos   # numpy int64 >> 是算术右移


def saturate_bits(v, bits=16):
    """饱和到 bits 位有符号范围（clamp）。"""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return np.clip(np.asarray(v, dtype=np.int64), lo, hi)


def acc_overflow_mask(acc):
    """检查累加器是否超出 40bit 有符号范围（统计用，正常应为全 False）。"""
    acc = np.asarray(acc, dtype=np.int64)
    return (acc > ACC_MAX) | (acc < ACC_MIN)
