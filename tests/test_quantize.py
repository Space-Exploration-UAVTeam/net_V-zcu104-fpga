"""
test_quantize.py — 定点量化工具自检
====================================

不需要真实模型数据，纯验证 quantize.py 的数学正确性。

运行：
    cd RL_project
    python3 -m pytest tests/test_quantize.py -v
    或（不用 pytest）
    python3 tests/test_quantize.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from golden_model import quantize as q


def test_to_fixed_roundtrip():
    """浮点 → 定点 → 回浮点，范围内误差应在 2^-FRAC 以内。"""
    # 用定点范围内的值测试回读（超出范围会饱和，那是 test_saturation 的事）
    max_val = q.q_max() / (2 ** q.cfg.FRAC_W)   # 范围内最大值
    x = np.array([0.0, 1.0, -1.0, 0.5, -0.25, 1.2345, -max_val * 0.5, max_val * 0.8])
    fixed = q.to_fixed(x)
    back = q.from_fixed(fixed)
    err = np.abs(back - x)
    assert np.all(err <= 2 ** -q.cfg.FRAC_W + 1e-9), f"量化回读误差过大: {err}"


def test_saturation():
    """超出范围的值应被饱和钳位，而不是回绕。"""
    q.set_q_format(data_w=8, int_w=4)   # 范围 [-8, 7.9375]
    fixed = q.to_fixed(np.array([100.0, -100.0]))
    assert fixed[0] == q.q_max(), f"正溢出未饱和: {fixed[0]}"
    assert fixed[1] == q.q_min(), f"负溢出未饱和: {fixed[1]}"
    q.set_q_format(data_w=16, int_w=5)  # 恢复默认


def test_saturating_accumulate():
    """饱和累加器：溢出时 clamp。"""
    q.set_q_format(data_w=8, int_w=4)
    acc = q.saturating_accumulate(q.q_max(), 1)   # 最大值+1 应停在最大值
    assert acc == q.q_max()
    acc = q.saturating_accumulate(q.q_min(), -1)  # 最小值-1 应停在最小值
    assert acc == q.q_min()
    # 正常累加
    acc = q.saturating_accumulate(5, 3)
    assert acc == 8
    q.set_q_format(data_w=16, int_w=5)


if __name__ == "__main__":
    test_to_fixed_roundtrip()
    test_saturation()
    test_saturating_accumulate()
    print("test_quantize: 全部 PASS")
