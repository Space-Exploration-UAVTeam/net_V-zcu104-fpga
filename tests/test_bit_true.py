"""
test_bit_true.py — bit-true 定点路径自检（阶段 2）
===================================================

用小样例【手算】验证定点原语语义（= RTL 语义）：
1. quantize_to：round-half-away-from-zero + 饱和
2. round_shift：加半 LSB 后算术右移（CUT_POS，round-half-toward-+∞）
3. ELU LUT：正支直通 / 负支查表 / 插值 / ≤-8 钳位
4. 单层定点 MAC + 再量化手算
5. sample_00 走 bit-true 全链，ΔV 定点 vs 浮点误差报告

运行：
    cd RL_project
    python3 tests/test_bit_true.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np

from golden_model import quantize as q
from golden_model import elu_lut
from golden_model import network

PASS = 0


def check(name, cond, detail=""):
    global PASS
    assert cond, f"[FAIL] {name}: {detail}"
    PASS += 1
    print(f"  [PASS] {name}")


def test_quantize_to():
    print("=== 1. quantize_to（规则①：half-away-from-zero + 饱和）===")
    # 1.2345 × 2^14 = 20226.048 → 20226
    check("1.2345@frac14 = 20226",
          q.quantize_to(np.array([1.2345]), 14)[0] == 20226)
    # 恰好 0.5 LSB：1.5×2^-14 @frac14 → 2（half 远离零）；负数 → -2
    check("tie +1.5LSB → 2", q.quantize_to(np.array([1.5 / 2**14]), 14)[0] == 2)
    check("tie -1.5LSB → -2", q.quantize_to(np.array([-1.5 / 2**14]), 14)[0] == -2)
    # 饱和到 int16
    check("3.0@frac14 饱和 32767", q.quantize_to(np.array([3.0]), 14)[0] == 32767)
    check("-3.0@frac14 饱和 -32768", q.quantize_to(np.array([-3.0]), 14)[0] == -32768)


def test_round_shift():
    print("=== 2. round_shift（规则②：加半 LSB 算术右移）===")
    # 384 = 1.5×2^8，CUT=8 → (384+128)>>8 = 2
    check("384 CUT8 → 2", q.round_shift(np.array([384]), 8)[0] == 2)
    # -384 → (-384+128)>>8 = -256>>8 = -1（half 向 +∞）
    check("-384 CUT8 → -1", q.round_shift(np.array([-384]), 8)[0] == -1)
    # 300 = 1.17×2^8 → (300+128)>>8 = 1
    check("300 CUT8 → 1", q.round_shift(np.array([300]), 8)[0] == 1)
    # -300 → (-300+128)>>8 = -172>>8 = -1（-1.17 四舍五入）
    check("-300 CUT8 → -1", q.round_shift(np.array([-300]), 8)[0] == -1)
    # CUT=0 恒等
    check("CUT0 恒等", q.round_shift(np.array([-7, 12345]), 0)[1] == 12345)


def test_elu_lut():
    print("=== 3. ELU LUT（f=5 精确表 / f=12 插值表）===")
    lut5 = elu_lut.build_elu_lut(5, 256, 8)     # 8·2^5=256 码 → 精确查表
    check("f=5 表项 257、无插值", lut5["n_entries"] == 257 and lut5["interp_bits"] == 0)
    y = elu_lut.elu_lut_apply(np.array([0, 96, -32, -256, -300, -255]), lut5)
    check("z=0 → 0", y[0] == 0)
    check("正支直通 z=96(3.0) → 96", y[1] == 96)
    # elu(-1.0) = e^-1-1 = -0.63212，×2^5 = -20.228 → -20
    check("z=-32(-1.0) → -20", y[2] == -20)
    check("z=-256(-8.0) 钳到 -32(-1.0)", y[3] == -32)
    check("z=-300(<-8) 钳到 -32", y[4] == -32)
    # elu(-255/32) = elu(-7.96875) ≈ -0.99965 → ×32 = -31.99 → -32
    check("z=-255 → -32", y[5] == -32)

    lut12 = elu_lut.build_elu_lut(12, 256, 8)   # 8·2^12=32768 码 → 256 档插值
    check("f=12 表项 257、interp 7bit",
          lut12["n_entries"] == 257 and lut12["interp_bits"] == 7)
    # 手算：z=-64（x=-1/64）→ u=32704, idx=255, frac=64；
    # T[255]=quantize(elu(-1/32))=-126, T[256]=0, dt=126
    # y = -126 + ((126×64 + 64)>>7) = -126 + 63 = -63
    y = elu_lut.elu_lut_apply(np.array([-64, -32768, 4096]), lut12)
    check("f=12 z=-64 插值 → -63", y[0] == -63, f"实际 {y[0]}")
    check("f=12 z=-32768(=-8) 钳到 -4096", y[1] == -4096)
    check("f=12 正支直通 z=4096(1.0)", y[2] == 4096)


def test_fixed_mac():
    print("=== 4. 定点 MAC + 再量化（手算）===")
    # x = [1.0, -1.0] @Q6.10 = [1024, -1024]；W = [0.5, -0.5] @Q2.14 = [8192, -8192]
    # acc = 1024×8192 + (-1024)×(-8192) = 16777216，acc_frac = 14+10 = 24
    # CUT = 24-11 = 13 → (16777216+4096)>>13 = 2048（=1.0 @Q5.11）
    x = np.array([1024, -1024], dtype=np.int64)
    W = np.array([[8192, -8192]], dtype=np.int64)
    acc = W @ x
    check("acc = 16777216", acc[0] == 16777216, f"实际 {acc[0]}")
    entry = {"cut_pos": 13, "bits": 16,
             "lut": elu_lut.build_elu_lut(11, 256, 8)}
    y = network.fixed_layer(acc, entry)
    check("再量化+ELU → 2048 (1.0@Q5.11)", y[0] == 2048, f"实际 {y[0]}")

    # 负 pre-act：W = [0.5, 0.5] → acc = 0 → y=0；W = [-0.5, -0.5] → acc = -16777216
    acc_neg = np.array([-16777216], dtype=np.int64)
    y_neg = network.fixed_layer(acc_neg, entry)
    # round_shift: (-16777216+4096)>>13 = -2048（=-1.0）→ LUT f=11: elu(-1)×2048
    # = round(-0.63212×2048) = round(-1294.6) = -1295
    check("负 pre-act → LUT(-1.0@Q5.11) = -1295", y_neg[0] == -1295,
          f"实际 {y_neg[0]}")


def test_sample00_fixed_chain():
    print("=== 5. sample_00 bit-true 全链 ===")
    from golden_model import reader
    import config.model_config as cfg

    x_raw = reader.read_test_input()
    z = network.normalize_input(x_raw)
    x_q = q.quantize_to(z, cfg.Q_FORMAT["input_frac"], cfg.Q_FORMAT["input_bits"])
    check("输入量化 7 维 int16", x_q.shape == (7,) and np.all(np.abs(x_q) < 32768))

    cache = network.build_fixed_cache()
    acc7 = network.forward_network_fixed(x_q, cache)
    check("acc7 在 40bit 内", abs(acc7) < (1 << 39), f"acc7={acc7}")

    dv_fixed = float(network.dequantize_dv(acc7, cache))
    _, outs = network.forward_network_float_traced(z)
    dv_float = float(outs[-1][0])
    golden = float(reader.read_layer_output(7)[0])
    err = abs(dv_fixed - dv_float)
    print(f"      ΔV_fixed={dv_fixed:.4f}  ΔV_float={dv_float:.4f}  "
          f"golden={golden}  定点vs浮点={err:.4f} m/s")
    check("定点 vs 浮点 ΔV 误差 < 1.5 m/s", err < 1.5, f"实际 {err:.4f}")
    check("定点 vs golden 误差 < 1.5 m/s", abs(dv_fixed - golden) < 1.5,
          f"实际 {abs(dv_fixed-golden):.4f}")


if __name__ == "__main__":
    test_quantize_to()
    test_round_shift()
    test_elu_lut()
    test_fixed_mac()
    test_sample00_fixed_chain()
    print(f"\n=== 全部 {PASS} 项检查 PASS ===")
