"""
reader.py — 读取模型同学交付的数据文件
======================================

读取 net_V 真实交付的文本文件（已落位到 data/，2026-08-12）：
  ① 权重     data/weights/layer_01_weight.txt      科学记数法
  ② 偏置     data/biases/layer_01_bias.txt         科学记数法
  ③ 归一化   data/net_V_input_normalization.txt    mean/var
  ④ 测试样本 data/test_samples/sample_00/          输入 + 逐层输出

【格式约定】（已与交付数据核对一致）
- 数值用科学记数法表达，有效数字 5 位，如 1.2345e-03、-5.6789E+2
- 权重：每行 = 一个输出神经元的全部输入权重，形状 (out_features, in_features)，
  与 PyTorch nn.Linear 的 weight 布局一致（layer_01 为 512 行×7 列）
- 偏置：每行一个数，长度 = 输出维度
- 真实模型无 BN（read_bn 仅为兼容保留，文件不存在时返回 None）

【使用方式】
    from golden_model.reader import read_weight, read_bias, read_normalization
    W = read_weight(1, rows=512, cols=7)   # 读第1层权重 → (512, 7) 数组
    b = read_bias(1)
    mean, var = read_normalization()

这个模块只做"读文件 + 解析成 numpy 数组"，不做任何量化或计算。
"""

import os
import re
import json
import numpy as np

# 项目根目录（data/ 的上级）
_PROJ_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DATA_DIR = os.path.join(_PROJ_ROOT, "data")

# 防止缺 numpy 时崩溃（用简单列表兜底）
try:
    _NP = True
except ImportError:
    _NP = False


def _data_dir():
    """数据根目录：以 config.DATA_DIR 为准（测试可临时改指假数据目录）。"""
    import config.model_config as cfg
    return getattr(cfg, "DATA_DIR", _DATA_DIR)


def _resolve_path(subdir, fname):
    """把 data/<subdir>/<fname> 解析成绝对路径。subdir 可为 "" 表示 data/ 根。"""
    full = os.path.join(_data_dir(), subdir, fname)
    if not os.path.exists(full):
        raise FileNotFoundError(
            f"找不到数据文件: {full}\n"
            f"请确认模型同学的数据已放到 data/{subdir}/ 下，且命名符合约定。"
        )
    return full


def _read_numbers(path):
    """读文本文件里的全部数值（跳过空行和 # 注释），返回 1D float64 数组。

    科学记数法 float() 直接能解析；一行可以有多个数（空格/逗号分隔）。
    """
    vals = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:                      # 跳过空行
                continue
            if line.startswith("#"):          # 跳过注释行
                continue
            for tok in line.replace(",", " ").split():
                if tok:
                    vals.append(float(tok))
    return np.array(vals, dtype=np.float64)


def read_weight(layer_no, rows=None, cols=None):
    """读第 layer_no 层权重。

    参数:
        layer_no : 层号，从 1 开始
        rows, cols: 期望的形状（用于校验 + 自动 reshape）
                   若给出，返回 (rows, cols) 的 2D 数组
                   若不给，返回 1D 数组（按文件顺序）
    返回:
        numpy 数组，float64

    文件布局已确认：每行 = 一个输出神经元，即 (out_features, in_features)，
    与 PyTorch nn.Linear 的 weight 一致。
    """
    import config.model_config as cfg

    fname = cfg.WEIGHT_PREFIX.format(layer_no) + ".txt"
    path = _resolve_path("weights", fname)

    arr = _read_numbers(path)

    # 形状校验
    if rows is not None and cols is not None:
        expected = rows * cols
        if arr.size != expected:
            raise ValueError(
                f"第{layer_no}层权重数量={arr.size}，期望 {rows}x{cols}={expected}。"
                f"请检查文件或 config 中的层结构。"
            )
        arr = arr.reshape(rows, cols)

    return arr


def read_bias(layer_no):
    """读第 layer_no 层偏置（txt，每行一个数），返回 numpy 数组（1D）。"""
    import config.model_config as cfg

    fname = cfg.BIAS_PREFIX.format(layer_no) + ".txt"
    path = _resolve_path("biases", fname)
    return _read_numbers(path)


def read_normalization():
    """读输入归一化参数 data/net_V_input_normalization.txt。

    返回:
        (mean, var)：两个 7 维 numpy 数组，z = (x - mean) / sqrt(var)

    文件行格式：feature_01：5.9142e+02   5.3181e+04（全角冒号分隔）。
    """
    path = _resolve_path("", "net_V_input_normalization.txt")
    mean, var = [], []
    num = re.compile(r"[-+]?\d+\.?\d*[eE][-+]?\d+|[-+]?\d+\.?\d*")
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            # 数据行形如 feature_01：5.9142e+02   5.3181e+04（全角冒号）；
            # 文件前面说明段的 feature_01: ...（半角冒号）要跳过
            if not line.startswith("feature_") or "：" not in line:
                continue
            vals = num.findall(line.split("：", 1)[1])   # 全角冒号后取两个数
            if len(vals) >= 2:
                mean.append(float(vals[0]))
                var.append(float(vals[1]))
    if not mean:
        raise ValueError(f"归一化文件未解析到任何 feature 行: {path}")
    return np.array(mean, dtype=np.float64), np.array(var, dtype=np.float64)


def read_bn(layer_no):
    """读第 layer_no 层 BN 参数。

    返回 dict 或 None：
        {"gamma": ndarray, "beta": ndarray, "mean": ndarray,
         "var": ndarray, "eps": float}
    若该层没有 BN 文件（或文件为空），返回 None。

    注意：真实模型 net_V 无 BN，此路径仅为 bn_fold.py 兼容保留。
    """
    import config.model_config as cfg

    fname = cfg.BN_PREFIX.format(layer_no) + ".json"
    path = os.path.join(_data_dir(), "bn", fname)
    if not os.path.exists(path):
        return None

    with open(path, "r") as f:
        d = json.load(f)
    if not d:   # 空 dict 视为无 BN
        return None

    return {
        "gamma": np.array(d["gamma"], dtype=np.float64),
        "beta": np.array(d["beta"], dtype=np.float64),
        "mean": np.array(d["mean"], dtype=np.float64),
        "var": np.array(d["var"], dtype=np.float64),
        "eps": float(d.get("eps", 1e-5)),
    }


def read_test_input(sample="sample_00"):
    """读测试样本的原始输入 input_raw.txt（7 维，未归一化）。

    参数:
        sample : 样本目录名，默认 "sample_00"
    返回:
        numpy 数组，1D
    """
    path = _resolve_path(os.path.join("test_samples", sample), "input_raw.txt")
    return _read_numbers(path)


def read_sample_normalized(sample="sample_00"):
    """读测试样本的归一化输入 input_normalized.txt（7 维）。"""
    path = _resolve_path(os.path.join("test_samples", sample), "input_normalized.txt")
    return _read_numbers(path)


def read_layer_output(layer_no, sample="sample_00"):
    """读测试样本第 layer_no 层的输出 layer_XX_output.txt（golden vector）。"""
    path = _resolve_path(os.path.join("test_samples", sample),
                         "layer_{:02d}_output.txt".format(layer_no))
    return _read_numbers(path)
