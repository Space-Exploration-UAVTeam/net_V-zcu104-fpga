"""
bn_fold.py — 把 BatchNorm 折叠进 FC 权重
=========================================

【为什么需要折叠】
老师清单提到模型可能有 BatchNorm。如果硬件直接实现 BN，需要一个除法/开方单元，
非常浪费。但 BN 在推理时是纯线性运算，可以合并进前一层的权重和 bias，硬件零成本。

【数学原理】
推理时 BN 的计算是：
    y = γ * (x - μ) / sqrt(σ² + ε) + β
  = (γ / sqrt(σ² + ε)) * x  +  (β - γ*μ / sqrt(σ² + ε))

对 FC 层 y = W·x + b 之后再过 BN，等价于一个新的 FC：
    W' = W * (γ / sqrt(σ² + ε))            # 按输出通道广播
    b' = b * (γ / sqrt(σ² + ε)) + (β - γ*μ / sqrt(σ² + ε))

【使用方式】
    from golden_model.bn_fold import fold_bn_into_fc
    W_new, b_new = fold_bn_into_fc(W, b, bn)
    然后正常做量化、存权重即可，硬件完全不知道有 BN 存在。

【注意】
- γ, β, μ, σ² 都是逐输出通道（神经元）的向量，长度 = 本层输出维度
- ε 是 BN 里的常数，防止除零，通常 1e-5，值由模型同学提供
"""

import numpy as np


def fold_bn_into_fc(W, b, bn):
    """把 BN 参数折叠进 FC 层的权重和 bias。

    参数:
        W : (in, out) 或 (out, in) 权重数组。注意：取决于文件排列顺序。
            默认按 W[out, in] 处理（out 是行）。
        b : (out,) 偏置数组
        bn: read_bn() 返回的 dict，含 gamma/beta/mean/var/eps
    返回:
        (W_new, b_new) 折叠后的权重和偏置（浮点）

    TODO: 确认模型同学文件的排列顺序（行优先/列优先）后，
          在 reader 处统一 reshape，这里假定 W 形状为 (out, in)。
    """
    gamma = np.asarray(bn["gamma"], dtype=np.float64)
    beta = np.asarray(bn["beta"], dtype=np.float64)
    mean = np.asarray(bn["mean"], dtype=np.float64)
    var = np.asarray(bn["var"], dtype=np.float64)
    eps = bn["eps"]

    scale = gamma / np.sqrt(var + eps)          # 逐通道缩放系数
    shift = beta - mean * scale                 # 逐通道偏移

    # 折叠：W' = W * scale，b' = b * scale + shift
    W_new = W * scale.reshape(-1, 1) if W.ndim == 2 else W * scale
    b_new = b * scale + shift

    return W_new, b_new
