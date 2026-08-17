"""
network.py — 网络级前向(7 层串行)
===================================

把 reader + layers 串起来, 实现完整网络的定点/浮点前向。
真实模型 net_V 无 BN, 不再做 BN 折叠(bn_fold.py 保留但此路径不用)。

【结构】(对应 config.LAYERS, 真实结构)
    input(7) → FC+ELU(512) ×6 → FC(1) 无激活, 输出 ΔV

【流程】
    1. 输入归一化: z = (x - mean) / sqrt(var)(normalize_input)
    2. 逐层读权重/偏置
    3. 浮点权重 → 定点(quantize)
    4. 前向(layers.fc_layer_forward)
    5. 输出传给下一层

【当前状态】
- 权重从 data/ 读(真实数据已落位)
- 浮点前向已与交付的逐层 golden vector 对齐(见 tests/test_golden_model.py)
- 定点前向仍是单一全局 Q 格式, 逐层 Q 格式位真对齐是阶段 2 的工作
"""

import numpy as np
from . import reader, quantize as q
from .layers import fc_layer_forward, fc_layer_forward_float
from . import elu_lut as _lut


def input_frac():
    """归一化输入的 Q 格式小数位(Q6.10)。"""
    import config.model_config as cfg
    return cfg.Q_FORMAT["input_frac"]


def layer_act_frac(layer_no):
    """第 layer_no 层(1~6)激活输出的 Q 格式小数位。"""
    import config.model_config as cfg
    return cfg.Q_FORMAT["act_frac"][layer_no]


def normalize_input(x):
    """输入归一化: z = (x - mean) / sqrt(var)(参数见 config.NORM_MEAN/VAR)。"""
    import config.model_config as cfg

    x = np.asarray(x, dtype=np.float64)
    mean = np.asarray(cfg.NORM_MEAN, dtype=np.float64)
    var = np.asarray(cfg.NORM_VAR, dtype=np.float64)
    return (x - mean) / np.sqrt(var)


def load_layer(layer_no, in_dim, out_dim):
    """读一层并定点化, 返回 (W_fixed, b_fixed, activation)。

    参数:
        layer_no: 层号(1 起)
        in_dim, out_dim: 本层输入/输出维度
    返回:
        W_fixed : (in, out) 定点整数权重
        b_fixed : (out,)   定点整数偏置
        act     : 激活函数字符串
    """
    import config.model_config as cfg

    # 1. 读浮点权重/偏置(文件布局 (out, in), 与 nn.Linear 一致)
    W = reader.read_weight(layer_no, rows=out_dim, cols=in_dim)  # (out, in)
    b = reader.read_bias(layer_no)                                # (out,)

    # 2. 转成硬件视角: W 形状 (in, out), 与 layers.fc_layer_forward 一致
    W = W.T

    # 3. 定点化
    W_fixed, b_fixed = q.quantize_layer(W, b)

    # 4. 激活函数
    act = cfg.LAYERS[layer_no - 1][2]

    return W_fixed, b_fixed, act


def forward_network(input_vec, cache=None):
    """完整网络前向(定点)。返回最终输出(浮点值, 量化后)。

    参数:
        input_vec: 7 维输入(浮点, 应为归一化后的值；原始值请先过 normalize_input)
        cache    : 预先加载的 {layer_no: (W_fixed, b_fixed, act)}, 
                   可避免每次重复读文件(见 load_network_cache)
    """
    import config.model_config as cfg

    x = np.asarray(input_vec, dtype=np.float64)

    if cache is None:
        cache = load_network_cache()

    for layer_no in range(1, len(cfg.LAYERS) + 1):
        W_fixed, b_fixed, act = cache[layer_no]
        x = fc_layer_forward(x, W_fixed, b_fixed, act)

    return x


def load_network_cache():
    """一次性加载所有层(读文件 + 定点化), 返回 dict 缓存。"""
    import config.model_config as cfg

    cache = {}
    for layer_no, (in_dim, out_dim, act) in enumerate(cfg.LAYERS, start=1):
        cache[layer_no] = load_layer(layer_no, in_dim, out_dim)
    return cache


def load_network_cache_float():
    """一次性加载所有层的浮点权重, 返回 {layer_no: (W(in,out), b, act)}。"""
    import config.model_config as cfg

    cache = {}
    for layer_no, (in_dim, out_dim, act) in enumerate(cfg.LAYERS, start=1):
        W = reader.read_weight(layer_no, rows=out_dim, cols=in_dim)
        b = reader.read_bias(layer_no)
        cache[layer_no] = (W.T, b, act)
    return cache


def forward_network_float(input_vec, cache=None):
    """纯浮点参考前向(不量化), 用于对比量化误差。"""
    x, _ = forward_network_float_traced(input_vec, cache=cache)
    return x


def forward_network_float_traced(input_vec, cache=None):
    """纯浮点前向, 并记录每层输出。

    返回:
        (最终输出, [layer_01 输出, ..., layer_07 输出])
    用于与交付的逐层 golden vector(data/test_samples/)对比。
    """
    import config.model_config as cfg

    x = np.asarray(input_vec, dtype=np.float64)

    if cache is None:
        cache = load_network_cache_float()

    layer_outs = []
    for layer_no in range(1, len(cfg.LAYERS) + 1):
        W, b, act = cache[layer_no]
        x = fc_layer_forward_float(x, W, b, act)
        layer_outs.append(x)

    return x, layer_outs


def compare_quantized_vs_float(input_vec, cache=None):
    """对比定点前向与浮点前向的差异, 评估量化误差。

    返回 dict: {"quantized": ..., "float": ..., "abs_err": ..., "rel_err": ...}
    """
    if cache is None:
        cache = load_network_cache()

    yq = forward_network(input_vec, cache=cache)
    yf = forward_network_float(input_vec)

    return {
        "quantized": yq,
        "float": yf,
        "abs_err": np.abs(yq - yf),
        "rel_err": np.abs(yq - yf) / (np.abs(yf) + 1e-12),
    }


# ---------------------------------------------------------------------------
# 阶段 2: bit-true 定点前向(与 RTL 逐 bit 一致)
# ---------------------------------------------------------------------------
#
# 【数据通路】(每层语义 = RTL 语义)
#   输入: PS 归一化后按 Q6.10 量化的 int16
#   权重: Q2.14 int16 ROM；bias: 按 acc_frac = w_frac + x_frac 量化(40bit)
#   MAC : int16×int16 乘积送 40bit 累加器(int64 模拟), 加 bias(同刻度)
#   再量化: round_shift(acc, CUT_POS) → saturate int16, CUT_POS = acc_frac - act_frac
#   激活: layer_01~06 过 ELU LUT；layer_07 线性, 输出累加器原值
#   输出: ΔV = acc7 × 2^(-acc_frac7), PS 浮点反量化


def build_fixed_cache():
    """读浮点权重并定点化, 返回 bit-true 前向用的缓存 dict。

    每层记录: W(int16, out×in), b(40bit, acc 刻度), cut_pos, lut,
              act_frac, bits(激活存储位宽), acc_frac, act
    """
    import config.model_config as cfg

    cache = {}
    for layer_no, (in_dim, out_dim, act) in enumerate(cfg.LAYERS, start=1):
        W = reader.read_weight(layer_no, rows=out_dim, cols=in_dim)  # (out, in)
        b = reader.read_bias(layer_no)

        w_frac = cfg.Q_FORMAT["weight_frac"][layer_no]
        x_frac = input_frac() if layer_no == 1 else layer_act_frac(layer_no - 1)
        acc_frac = w_frac + x_frac
        W_q = q.quantize_to(W, w_frac, bits=16)
        b_q = q.quantize_to(b, acc_frac, bits=q.ACC_BITS)

        entry = {
            "W": W_q, "b": b_q, "act": act, "acc_frac": acc_frac,
            "x_frac": x_frac, "w_frac": w_frac,
            "cut_pos": None, "lut": None, "act_frac": None,
            "bits": cfg.Q_FORMAT["act_bits"],
        }
        if act == "elu":
            act_frac = layer_act_frac(layer_no)
            entry["act_frac"] = act_frac
            entry["cut_pos"] = acc_frac - act_frac
            entry["lut"] = _lut.build_elu_lut(act_frac, cfg.ELU_LUT_N,
                                              cfg.ELU_NEG_RANGE)
        cache[layer_no] = entry
    return cache


def fixed_layer(acc, entry, sat_counter=None):
    """累加器结果 → 再量化 → 饱和 → ELU LUT(单层后处理, bit-true)。

    线性层(layer_07)不应调用本函数——直接输出 acc。
    sat_counter: 若给 dict, 累计饱和次数: ["pos"]=正支钳位(有害), 
    ["neg"]=负支钳位(对 ELU 无害——钳位值经 LUT 仍输出 -1, 与浮点一致)。
    """
    y = q.round_shift(acc, entry["cut_pos"])
    y_sat = q.saturate_bits(y, entry["bits"])
    if sat_counter is not None:
        hi = (1 << (entry["bits"] - 1)) - 1
        lo = -(1 << (entry["bits"] - 1))
        sat_counter["pos"] = sat_counter.get("pos", 0) + int(np.count_nonzero(y > hi))
        sat_counter["neg"] = sat_counter.get("neg", 0) + int(np.count_nonzero(y < lo))
    return _lut.elu_lut_apply(y_sat, entry["lut"])


def forward_network_fixed(x_q, cache=None):
    """单样本 bit-true 定点前向。

    参数:
        x_q  : 7 维 int 数组(Q6.10 定点, 即 PS 送来的值)
        cache: build_fixed_cache() 的缓存
    返回:
        acc7 : int 标量, layer_07 累加器原值(刻度 2^(-acc_frac7))。
               ΔV = acc7 / 2^acc_frac7(PS 浮点反量化)
    """
    if cache is None:
        cache = build_fixed_cache()

    x = np.asarray(x_q, dtype=np.int64)
    for layer_no in sorted(cache):
        e = cache[layer_no]
        acc = e["W"] @ x + e["b"]            # int64 模拟 40bit 累加器
        if e["act"] == "linear":
            return int(acc[0])
        x = fixed_layer(acc, e)
    raise RuntimeError("网络没有线性输出层")


def forward_network_fixed_batch(X_q, cache=None, sat_counts=None,
                                acc_peaks=None):
    """批量 bit-true 定点前向(统计脚本用, 向量化)。

    参数:
        X_q       : (N, 7) int 数组(Q6.10 定点)
        sat_counts: 若给 dict, 按层累计再量化饱和次数 {layer_no: count}
        acc_peaks : 若给 dict, 记录每层累加器 |acc| 峰值(校验 40bit 不溢出)
    返回:
        (N,) int64 数组, layer_07 累加器原值

    实现说明: int16×int16 乘积 ≤ 2^30, 512 项累加 < 2^40, 而 float64 尾数
    53bit——整数在 2^53 内的加减乘在 float64 下精确, 所以 matmul 用
    float64 算再转回 int64 是逐 bit 精确的(纯整数运算与求和顺序无关)。
    """
    if cache is None:
        cache = build_fixed_cache()

    x = np.asarray(X_q, dtype=np.int64)
    for layer_no in sorted(cache):
        e = cache[layer_no]
        # 精确整数技巧: float64 matmul(断言峰值远低于 2^53)
        acc = (x.astype(np.float64) @ e["W"].astype(np.float64).T
               + e["b"].astype(np.float64))
        assert np.abs(acc).max() < 2.0 ** 52, "超出 float64 精确整数范围"
        acc = acc.astype(np.int64)
        if acc_peaks is not None:
            acc_peaks[layer_no] = max(acc_peaks.get(layer_no, 0),
                                      int(np.abs(acc).max()))
        if e["act"] == "linear":
            return acc[:, 0]
        sat = {}
        x = fixed_layer(acc, e, sat_counter=sat)
        if sat_counts is not None:
            prev_p, prev_n = sat_counts.get(layer_no, (0, 0))
            sat_counts[layer_no] = (prev_p + sat.get("pos", 0),
                                    prev_n + sat.get("neg", 0))
    raise RuntimeError("网络没有线性输出层")


def dequantize_dv(acc7, cache=None):
    """layer_07 累加器原值 → 浮点 ΔV(PS 侧反量化): ΔV = acc × 2^(-acc_frac7)。"""
    import config.model_config as cfg

    if cache is None:
        cache = build_fixed_cache()
    acc_frac7 = cache[len(cfg.LAYERS)]["acc_frac"]
    return np.asarray(acc7, dtype=np.float64) / (2.0 ** acc_frac7)
