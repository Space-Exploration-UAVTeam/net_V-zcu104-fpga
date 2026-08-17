"""
layers.py — 单层前向计算（与硬件行为对齐）
===========================================

实现 FC 层 + 激活（ELU / linear / ReLU）的定点前向，行为与 RTL 一致。

【计算流水】（与硬件 neuron 对齐）
    1. 输入浮点 → 定点（to_fixed）
    2. W·x + b（定点累加，饱和）
    3. 累加结果 → 定点回浮点（量化后的浮点）
    4. 激活：按层配置（真实模型 net_V：隐藏层 ELU(α=1)，输出层 linear）
    5. 输出 → 下一层输入（已是定点量化后的值）

【重要】这里的每步都要和 RTL 行为一致：
    - 累加器饱和用 saturating_accumulate（不是普通 numpy 加法）
    - 量化舍入用 quantize.to_fixed
    - 输出给下一层时已经是量化后的值（硬件就是这样，下一层接收的是量化值）
"""

import numpy as np
from . import quantize as q


def relu(x):
    """ReLU 激活：负数归零。x 可以是标量或数组。"""
    return np.maximum(np.asarray(x, dtype=np.float64), 0.0)


def elu(x, alpha=1.0):
    """ELU 激活：x≥0 直通；x<0 为 alpha*(e^x - 1)（负向饱和到 -alpha）。"""
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0, x, alpha * (np.exp(x) - 1.0))


def apply_activation(y, activation):
    """按层配置应用激活函数。"""
    if activation == "elu":
        return elu(y)
    if activation == "relu":
        return relu(y)
    if activation in ("linear", "none"):
        return y
    raise ValueError(f"不支持的激活函数: {activation}")


def fc_layer_forward(x, W, b, activation="linear", do_quantize=True):
    """单层前向：y = act(quantize(W·x + b))。

    参数:
        x          : 输入（浮点或定点整数）。长度 = W 的行数（输入维度）
        W          : 权重。形状 (in, out)
        b          : 偏置。长度 = out
        activation : "elu" / "linear" / "relu"（"none" 等价于 "linear"）
        do_quantize: 是否做定点量化（True=模拟硬件，False=纯浮点参考）
    返回:
        y : 输出（浮点值，但已经过量化/饱和处理，等价于硬件输出回读）

    注意：本函数假定 x 是浮点。若 x 已经是定点整数，请先 from_fixed 转换。
    """
    x = np.asarray(x, dtype=np.float64)
    W = np.asarray(W, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)

    # 1. 输入定点化（硬件输入是定点的）
    x_fixed = q.to_fixed(x)

    # 2. 权重/偏置定点化（硬件里存的）
    W_fixed = q.to_fixed(W)
    b_fixed = q.to_fixed(b)

    # 3. 累加：逐输出通道算 W_fixed·x_fixed
    #    两个定点数相乘结果是 2^(2F) 刻度（F=FRAC_W）
    #    硬件累加器比数据宽（乘积 2*DATA_W + log2(输入数) 位），
    #    中间累加不饱和，只在最终输出时才饱和到数据宽度。
    #    Python int64（64位）足够容纳 41 位累加，无需手动钳位。
    in_dim, out_dim = W.shape
    acc = np.zeros(out_dim, dtype=np.int64)
    for i in range(in_dim):
        term = W_fixed[i, :] * x_fixed[i]       # 广播乘，2^(2F) 刻度
        acc = acc + term                         # 宽累加器，不钳位

    # 4. 乘积右移 F 位回到 2^F 刻度（硬件算术右移量化，StoneZhao 的 >>>CUT_POS）
    acc = acc >> q.cfg.FRAC_W
    #    然后加 bias（bias 是 2^F 刻度）
    acc = acc + b_fixed

    # 5. 最终输出饱和到数据宽度（这是硬件真正做饱和的地方）
    acc = np.clip(acc, q.q_min(), q.q_max())

    # 6. 定点整数回浮点
    y = q.from_fixed(acc)

    # 7. 激活
    return apply_activation(y, activation)


def fc_layer_forward_float(x, W, b, activation="linear"):
    """纯浮点参考（不做定点量化），用于验证量化误差。

    与 fc_layer_forward 的区别：这里用浮点 numpy 直接算，用来对比
    "量化引入了多少误差"。硬件最终必须匹配 fc_layer_forward（量化版）。
    """
    x = np.asarray(x, dtype=np.float64)
    W = np.asarray(W, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)

    y = W.T @ x + b

    return apply_activation(y, activation)
