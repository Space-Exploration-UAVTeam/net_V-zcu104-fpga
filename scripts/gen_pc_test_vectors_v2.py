#!/usr/bin/env python3
# gen_pc_test_vectors_v2.py — 生成 v2 交付 100 实例的 PC 端测试向量（阶段 v2-4）
#
# 数据源（神经网络部署输入_v2/网络预测实例/）：
#   raw      = net_V_test_raw_inputs.npy（100×7 原始物理量）
#   dv_float = layer_07_output.npy（交付的浮点 ΔV，判定用期望）
#   dv_fixed/acc7_fixed = scripts/validate_v2.py 跑定点 bit-true 的保存结果
#                       （sdk/pc_client/_v2_*.npy；先跑 validate_v2.py 再跑本脚本）
#
# 产物：sdk/pc_client/pc_test_vectors_v2.json
#   [{"name": "case_000", "raw": [7 floats], "dv_float": ...,
#     "dv_fixed": ..., "acc7_fixed": int}, ...]
#
# 用法（工作目录 RL_project）：
#   python3 scripts/gen_pc_test_vectors_v2.py
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import config.model_config as cfg

V2_CASES = os.path.join(cfg._PROJ_ROOT, "..", "神经网络部署输入_v2",
                        "网络预测实例")
OUT_DIR = os.path.join(cfg._PROJ_ROOT, "sdk", "pc_client")
OUT = os.path.join(OUT_DIR, "pc_test_vectors_v2.json")


def main():
    raw = np.load(os.path.join(V2_CASES, "net_V_test_raw_inputs.npy"))
    dv_float = np.load(os.path.join(V2_CASES, "layer_07_output.npy"))[:, 0]
    dv_fixed = np.load(os.path.join(OUT_DIR, "_v2_dv_fixed.npy"))
    acc7 = np.load(os.path.join(OUT_DIR, "_v2_acc7_fixed.npy"))
    assert raw.shape == (100, 7) and dv_float.shape == (100,) \
        and dv_fixed.shape == (100,) and acc7.shape == (100,)

    out = []
    for i in range(100):
        out.append({
            "name": "case_%03d" % i,
            "raw": [float(v) for v in raw[i]],
            "dv_float": float(dv_float[i]),   # 判定用期望（交付浮点）
            "dv_fixed": float(dv_fixed[i]),   # 参考：定点 ΔV
            "acc7_fixed": int(acc7[i]),       # 参考：40bit 累加器原值
        })
    with open(OUT, "w") as f:
        json.dump(out, f, indent=1)
    print("OK: %d 组写入 %s" % (len(out), OUT))
    print("ΔV 范围 [%.2f, %.2f]，均值 %.2f m/s" %
          (dv_float.min(), dv_float.max(), dv_float.mean()))


if __name__ == "__main__":
    main()
