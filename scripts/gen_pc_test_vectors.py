#!/usr/bin/env python3
# gen_pc_test_vectors.py — 生成 PC 端 UDP 客户端用的 27 组测试向量（阶段 5 以太网）
#
# 与 gen_golden_vectors.py 同一采样链（sample_00 + seed=777 随机 10 组 +
# 16 组边界），但导出的是**原始物理量 float + 浮点前向期望 ΔV**
# （板端量化/定点与 golden bit-true 已在 RTL 三重仿真和串口自检里分别验证；
#  以太网联测的判定对象是端到端 ΔV，容差 0.5 m/s，浮点期望足够）。
#
# 产物：sdk/pc_client/pc_test_vectors.json
#   [{"name": "s00_sample_00", "raw": [7 floats], "dv_float": ..., "dv_fixed": ...,
#     "acc7_fixed": int}, ...]
#
# 运行（工作目录 RL_project）：
#   python3 scripts/gen_pc_test_vectors.py
import sys, os, json

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "scripts"))

import numpy as np
import config.model_config as cfg
from golden_model import network, quantize as q, reader
from fixed_point_stats import sample_inputs
from gen_golden_vectors import make_boundary_samples

OUT = os.path.join(cfg._PROJ_ROOT, "sdk", "pc_client", "pc_test_vectors.json")
RANDOM_SEED = 777
N_RANDOM = 10


def main():
    cache = network.build_fixed_cache()
    cache_f = network.load_network_cache_float()

    samples = [("s00_sample_00", np.asarray(reader.read_test_input(),
                                          dtype=np.float64))]
    X_rand = sample_inputs(N_RANDOM, RANDOM_SEED)
    for i in range(N_RANDOM):
        samples.append(("s{:02d}_rand_{:02d}".format(i + 1, i),
                        np.asarray(X_rand[i], dtype=np.float64)))
    for k, (name, _cat, v) in enumerate(make_boundary_samples()):
        samples.append(("s{:02d}_{}".format(11 + k, name), v))
    assert len(samples) == 27

    out = []
    for name, x_raw in samples:
        z = network.normalize_input(x_raw)
        x_q = q.quantize_to(z, cfg.Q_FORMAT["input_frac"],
                            cfg.Q_FORMAT["input_bits"])
        acc7 = network.forward_network_fixed(x_q, cache)
        dv_fixed = float(network.dequantize_dv(acc7, cache))
        dv_float = float(network.forward_network_float_traced(z, cache_f)[0][0])
        out.append({
            "name": name,
            "raw": [float(v) for v in x_raw],
            "dv_float": dv_float,          # 判定用期望（浮点前向）
            "dv_fixed": dv_fixed,          # 参考：定点 ΔV
            "acc7_fixed": int(acc7),       # 参考：40bit 累加器原值
        })
        print("{}: dv_float={:.4f} dv_fixed={:.4f}".format(
            name, dv_float, dv_fixed))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(out, f, indent=1)
    print("\nOK: {} 组写入 {}".format(len(out), OUT))


if __name__ == "__main__":
    main()
