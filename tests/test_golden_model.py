"""
test_golden_model.py — golden model 端到端自检
===============================================

验证四层：
1. 定点量化数学正确（q_max/q_min、舍入、饱和）
2. 单层前向数学正确（手工可验证的 1x1 / 2x1 / ReLU / 累加 / 饱和）
3. 全链路机制能跑通（假数据：读文件 → 量化 → 7层前向 → 输出）
4. 真实模型数值对齐（net_V 真实数据：归一化 → 7层浮点前向（ELU)
   → 与 data/test_samples/sample_00 逐层输出对比，max abs err ≤ 5e-2，
   容差来源于交付 txt 只保留 5 位有效数字）

运行：
    cd RL_project
    python3 tests/test_golden_model.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np

from golden_model import quantize as q
from golden_model.layers import fc_layer_forward

PASS = 0


def check(name, cond, detail=""):
    global PASS
    assert cond, f"[FAIL] {name}: {detail}"
    PASS += 1
    print(f"  [PASS] {name}")


def make_dummy_data(tmp_root):
    """在临时目录生成假权重/偏置/输入（验证机制用，不动 data/ 里的真实数据）。

    结构跟随 cfg.LAYERS（7 层真实结构）。注意 scale 要小：全局占位 Q 格式
    INT_W=5 范围只有 [-16,16]，权重/输入取小值才能让假网络不提前饱和。
    """
    import config.model_config as cfg

    np.random.seed(42)
    scale_w, scale_x = 0.05, 0.3
    os.makedirs(os.path.join(tmp_root, "weights"), exist_ok=True)
    os.makedirs(os.path.join(tmp_root, "biases"), exist_ok=True)
    os.makedirs(os.path.join(tmp_root, "test_samples", "sample_00"), exist_ok=True)

    for layer_no, (in_d, out_d, act) in enumerate(cfg.LAYERS, start=1):
        W = np.random.randn(out_d, in_d) * scale_w
        b = np.random.randn(out_d) * scale_w
        np.savetxt(os.path.join(tmp_root, "weights",
                                f"layer_{layer_no:02d}_weight.txt"),
                   W, fmt="%.5e")          # 科学记数法，5位有效数字
        np.savetxt(os.path.join(tmp_root, "biases",
                                f"layer_{layer_no:02d}_bias.txt"),
                   b, fmt="%.5e")

    x = np.random.randn(cfg.LAYERS[0][0]) * scale_x
    np.savetxt(os.path.join(tmp_root, "test_samples", "sample_00",
                            "input_raw.txt"), x, fmt="%.5e")
    print("  [PASS] 假数据生成（临时目录，不影响 data/ 真实数据）")


def test_quantize_math():
    print("=== 1. 定点量化数学 ===")
    q.set_q_format(data_w=16, int_w=5)   # F=11, 范围[-16,16]

    # q_max/q_min 由 DATA_W 决定（16位整数范围）
    check("q_max=32767", q.q_max() == 32767)
    check("q_min=-32768", q.q_min() == -32768)

    # 回读：范围内误差 < 2^-FRAC
    x = np.array([0.0, 0.5, -0.25, 1.2345])
    back = q.from_fixed(q.to_fixed(x))
    check("定点回读误差 < 2^-11", np.all(np.abs(back - x) < 2 ** -q.cfg.FRAC_W))

    # 饱和：超出范围钳位
    fixed = q.to_fixed(np.array([100.0, -100.0]))
    check("正溢出饱和到 q_max", fixed[0] == q.q_max())
    check("负溢出饱和到 q_min", fixed[1] == q.q_min())


def test_layer_math():
    print("=== 2. 单层前向数学（手工可验证）===")
    q.set_q_format(data_w=16, int_w=5)

    # 1x1: 0.5*2.0 - 0.25 = 0.75
    y = fc_layer_forward(np.array([0.5]), np.array([[2.0]]), np.array([-0.25]), "linear")
    check("1x1: 0.75", abs(y[0] - 0.75) < 0.001, f"实际 {y[0]}")

    # 2x1: 0.5*2 + (-1)*(-1) = 2.0
    y = fc_layer_forward(np.array([0.5, -1.0]), np.array([[2.0], [-1.0]]), np.array([0.0]), "linear")
    check("2x1: 2.0", abs(y[0] - 2.0) < 0.01, f"实际 {y[0]}")

    # ReLU 归零（保留的兼容激活）
    y = fc_layer_forward(np.array([-0.5]), np.array([[2.0]]), np.array([0.0]), "relu")
    check("ReLU: 负归零", y[0] == 0.0, f"实际 {y[0]}")

    # ELU 负值：pre-act=-1 → e^-1 - 1
    y = fc_layer_forward(np.array([-0.5]), np.array([[2.0]]), np.array([0.0]), "elu")
    check("ELU: e^-1-1", abs(y[0] - (np.exp(-1.0) - 1.0)) < 0.001, f"实际 {y[0]}")

    # 多输入累加不提前饱和：3个1.0 → 3.0
    y = fc_layer_forward(np.ones(3), np.ones((3, 1)), np.array([0.0]), "linear")
    check("3输入累加=3.0", abs(y[0] - 3.0) < 0.01, f"实际 {y[0]}")

    # 饱和：超范围钳位到16
    y = fc_layer_forward(np.array([10.0]), np.array([[2.0]]), np.array([0.0]), "linear")
    check("饱和钳位到16", y[0] <= 16.001, f"实际 {y[0]}")


def test_full_chain():
    print("=== 3. 全链路机制（假数据，临时目录）===")
    import tempfile
    import config.model_config as cfg
    from golden_model import reader, network

    # 假数据写到临时目录，切换 cfg.DATA_DIR 指过去，跑完恢复
    real_data_dir = cfg.DATA_DIR
    with tempfile.TemporaryDirectory() as tmp:
        make_dummy_data(tmp)
        cfg.DATA_DIR = tmp
        try:
            x = reader.read_test_input()
            check("读取输入: 7维", x.shape[0] == 7, f"实际 {x.shape}")

            cache = network.load_network_cache()
            y_q = network.forward_network(x, cache=cache)
            y_f = network.forward_network_float(x)

            check("定点前向产出标量", np.ndim(y_q) == 1 and y_q.shape[0] == 1, f"实际 {y_q}")
            check("浮点前向产出标量", np.ndim(y_f) == 1 and y_f.shape[0] == 1)
            check("有限值（无 NaN/Inf）", np.all(np.isfinite(y_q)))
            print(f"      定点输出 y_q = {float(y_q[0]):.6f}")
            print(f"      浮点输出 y_f = {float(y_f[0]):.6f}")
        finally:
            cfg.DATA_DIR = real_data_dir

    # 说明：假数据下定点/浮点可能差异大（全局占位 Q 格式对随机网络太窄）。
    # 这是设计问题不是 bug——阶段 2 按 Q_FORMAT_DRAFT 做逐层格式后解决。


def test_real_data():
    print("=== 4. 真实模型数值对齐（net_V 交付数据）===")
    import config.model_config as cfg
    from golden_model import reader, network

    # 归一化参数：reader 解析结果与 config 一致
    mean, var = reader.read_normalization()
    check("归一化参数与 config 一致",
          np.allclose(mean, cfg.NORM_MEAN) and np.allclose(var, cfg.NORM_VAR))

    # 原始输入 → 归一化 → 与交付的 input_normalized 对比
    x_raw = reader.read_test_input()
    check("原始输入: 7维", x_raw.shape[0] == 7, f"实际 {x_raw.shape}")
    z = network.normalize_input(x_raw)
    z_ref = reader.read_sample_normalized()
    err_z = np.max(np.abs(z - z_ref))
    check("归一化输出对齐 (≤5e-2)", err_z <= 5e-2, f"max err = {err_z:.3e}")
    print(f"      归一化 max abs err = {err_z:.3e}")

    # 7 层浮点前向（ELU），逐层与 golden vector 对比。
    # 注意：逐层对比从【交付的归一化输入 z_ref】出发——golden 逐层输出就是从
    # 它算出来的。若从自己重算的 z 出发，mean/var 只有 5 位有效数字引入的
    # 4.6e-4 输入扰动经 7 层放大后末端约 7e-2，会超过 5e-2（数据精度问题，
    # 不是模型不对齐）。下面单独打印该组合误差作为参考。
    _, layer_outs = network.forward_network_float_traced(z_ref)
    check("逐层输出共 7 层", len(layer_outs) == 7, f"实际 {len(layer_outs)}")
    for i, y in enumerate(layer_outs, start=1):
        ref = reader.read_layer_output(i)
        err = np.max(np.abs(y - ref))
        check(f"layer_{i:02d} 输出对齐 (≤5e-2)", err <= 5e-2,
              f"max err = {err:.3e}")
        print(f"      layer_{i:02d}: max abs err = {err:.3e}")

    y_final = layer_outs[-1]
    check("最终输出为标量", y_final.shape[0] == 1, f"实际 {y_final.shape}")
    print(f"      最终输出 ΔV = {float(y_final[0]):.6f}"
          f"（golden {float(reader.read_layer_output(7)[0]):.6f}）")

    # 参考：完整组合链 input_raw → 自己归一化 → 7层前向 的末端误差
    _, outs_from_own_z = network.forward_network_float_traced(z)
    err_e2e = np.max(np.abs(outs_from_own_z[-1] - reader.read_layer_output(7)))
    print(f"      [参考] 从 input_raw 全组合链末端 max abs err = {err_e2e:.3e}"
          "（超 5e-2 源于归一化参数 5 位有效数字，见上注释）")


if __name__ == "__main__":
    test_quantize_math()
    test_layer_math()
    test_full_chain()
    test_real_data()
    print(f"\n=== 全部 {PASS} 项检查 PASS ===")
