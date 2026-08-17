"""
test_elu.py — ELU 激活函数边界自检
===================================

真实模型 net_V 的隐藏层激活是 ELU(α=1)：
    y = x           (x ≥ 0)
    y = e^x - 1     (x < 0)，负向饱和到 -1

验证边界行为：x=0、正值直通、负大值饱和到 -1、已知点数值。

运行：
    cd RL_project
    python3 tests/test_elu.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np

from golden_model.layers import elu, fc_layer_forward_float

PASS = 0


def check(name, cond, detail=""):
    global PASS
    assert cond, f"[FAIL] {name}: {detail}"
    PASS += 1
    print(f"  [PASS] {name}")


def test_elu_boundary():
    print("=== ELU 边界行为 ===")

    # x = 0：连续点，y = 0
    check("x=0 → 0", elu(0.0) == 0.0, f"实际 {elu(0.0)}")

    # 正值直通（线性区）
    x = np.array([0.5, 1.0, 100.0])
    check("正值直通", np.array_equal(elu(x), x), f"实际 {elu(x)}")

    # 负大值饱和到 -1（e^x → 0）
    check("负大值饱和到 -1", abs(elu(-100.0) - (-1.0)) < 1e-15,
          f"实际 {elu(-100.0)}")

    # 已知点：elu(-1) = e^-1 - 1 ≈ -0.6321
    check("elu(-1) = e^-1 - 1",
          abs(elu(-1.0) - (np.exp(-1.0) - 1.0)) < 1e-15, f"实际 {elu(-1.0)}")

    # 负小值在 (-1, 0) 内，且 0 附近连续（elu(-ε) ≈ -ε，float64 抵消误差 ~1e-17）
    check("0 附近负侧连续", abs(elu(-1e-12) - (-1e-12)) < 1e-15,
          f"实际 {elu(-1e-12)}")
    y = elu(np.array([-2.0, -0.1]))
    check("负值落在 (-1, 0)", np.all((y > -1.0) & (y < 0.0)), f"实际 {y}")


def test_elu_in_layer():
    print("=== ELU 接入单层前向（浮点路径）===")

    # pre-act > 0 直通：0.5*2.0 = 1.0 → 1.0
    y = fc_layer_forward_float(np.array([0.5]), np.array([[2.0]]),
                               np.array([0.0]), "elu")
    check("正 pre-act 直通", abs(y[0] - 1.0) < 1e-12, f"实际 {y[0]}")

    # pre-act < 0 走指数：-0.5*2.0 = -1.0 → e^-1 - 1
    y = fc_layer_forward_float(np.array([-0.5]), np.array([[2.0]]),
                               np.array([0.0]), "elu")
    check("负 pre-act 走 e^x-1", abs(y[0] - (np.exp(-1.0) - 1.0)) < 1e-12,
          f"实际 {y[0]}")

    # linear 层不激活：-0.5*2.0 = -1.0 → -1.0
    y = fc_layer_forward_float(np.array([-0.5]), np.array([[2.0]]),
                               np.array([0.0]), "linear")
    check("linear 不激活", abs(y[0] - (-1.0)) < 1e-12, f"实际 {y[0]}")


if __name__ == "__main__":
    test_elu_boundary()
    test_elu_in_layer()
    print(f"\n=== 全部 {PASS} 项检查 PASS ===")
