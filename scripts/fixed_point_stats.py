"""
fixed_point_stats.py — 定点部署误差统计验证（阶段 2 验收脚本）
==============================================================

按 net_V_input_ranges.txt 的包络均匀采样 2 万组输入，对比：
  浮点参考链（float64，txt 权重即"真值"） vs  bit-true 定点链（RTL 语义）

输出：
  - 每层激活再量化的饱和次数/比例（>0.1% 说明该层 Q 格式整数位不够）
  - 每层累加器峰值（校验 40bit 不溢出）
  - ΔV 绝对误差 mean/max/p99/p99.9、相对误差
  - 验收线：p99.9 ≤ 1.5 m/s 且 max ≤ 5 m/s

运行：
    cd RL_project
    python3 scripts/fixed_point_stats.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import config.model_config as cfg
from golden_model import network, quantize as q

SEED = 20260812
N_SAMPLES = 20000
CHUNK = 4000          # 分批跑，控制内存

# 验收线
P999_LIMIT = 1.5      # m/s
MAX_LIMIT = 5.0       # m/s


def sample_inputs(n, seed):
    """按 net_V_input_ranges.txt 包络均匀采样（特征顺序与归一化文件一致）。"""
    rng = np.random.default_rng(seed)
    h0 = rng.uniform(400, 800, n)
    hf = rng.uniform(400, 800, n)
    I0 = rng.uniform(1.0472, 1.3963, n)
    dI = rng.uniform(0, 0.087266, n)
    dO = rng.uniform(-3.1416, 0, n)
    fm = rng.uniform(5e-4, 5e-3, n)
    tf = rng.uniform(0, 3.1536e7, n)
    # feature_01..07: h0, I0, hf-h0, If-I0, omegaf-omega0, fmax, tf
    return np.stack([h0, I0, hf - h0, dI, dO, fm, tf], axis=1)


def forward_float_batch(Z, cache_f):
    """批量浮点参考前向（expm1 只在负支求值，避免溢出警告）。"""
    x = Z
    for layer_no in sorted(cache_f):
        W, b, act = cache_f[layer_no]
        x = x @ W + b
        if act == "elu":
            neg = x < 0
            x = np.where(neg, np.expm1(np.where(neg, x, 0.0)), x)
    return x[:, 0]


def main():
    print(f">>> 采样 {N_SAMPLES} 组输入（seed={SEED}）...")
    X = sample_inputs(N_SAMPLES, SEED)
    Z = network.normalize_input(X)
    print(f"    归一化输入范围 [{Z.min():.3f}, {Z.max():.3f}]")

    # 输入量化（PS 侧，Q6.10）
    x_q = q.quantize_to(Z, cfg.Q_FORMAT["input_frac"],
                        bits=cfg.Q_FORMAT["input_bits"])

    # 浮点参考 & 定点缓存
    cache_f = network.load_network_cache_float()
    cache_x = network.build_fixed_cache()

    print(">>> 定点配置：")
    print(f"    输入 Q6.10 int16；权重逐层 frac="
          f"{[cfg.Q_FORMAT['weight_frac'][l] for l in range(1, 8)]} int16；"
          f"激活 {cfg.Q_FORMAT['act_bits']}bit")
    for l in sorted(cache_x):
        e = cache_x[l]
        if e["act"] == "elu":
            lut = e["lut"]
            print(f"    layer_{l:02d}: act_frac={e['act_frac']:2d}  "
                  f"CUT_POS={e['cut_pos']:2d}  "
                  f"LUT {lut['n_entries']} 项/interp {lut['interp_bits']} bit")
        else:
            print(f"    layer_{l:02d}: linear，acc_frac={e['acc_frac']}，不截位")

    print(">>> 跑浮点/定点全链...")
    dv_f = np.empty(N_SAMPLES)
    dv_x = np.empty(N_SAMPLES)
    sat_counts, acc_peaks = {}, {}
    for s in range(0, N_SAMPLES, CHUNK):
        t = slice(s, s + CHUNK)
        dv_f[t] = forward_float_batch(Z[t], cache_f)
        acc7 = network.forward_network_fixed_batch(
            x_q[t], cache=cache_x, sat_counts=sat_counts, acc_peaks=acc_peaks)
        dv_x[t] = network.dequantize_dv(acc7, cache_x)

    # ---- 报告 ----
    print("\n=== 1. 各层再量化饱和（激活位宽截位触发） ===")
    print("    （正支钳位=有害；负支钳位对 ELU 无害，钳位值经 LUT 仍输出 -1）")
    worst = 0.0
    for l in sorted(sat_counts):
        pos, neg = sat_counts[l]
        denom = N_SAMPLES * cfg.LAYERS[l - 1][1]
        worst = max(worst, pos / denom)
        print(f"    layer_{l:02d}: 正支 {pos:6d} 次 ({pos/denom:.3e})   "
              f"负支 {neg:8d} 次 ({neg/denom:.3e})")
    print(f"    最大单层正支饱和率: {worst:.3e}（阈值 0.1% = 1e-3）")

    print("\n=== 2. 累加器峰值（40bit 范围 ±2^39 ≈ ±5.50e11） ===")
    for l in sorted(acc_peaks):
        print(f"    layer_{l:02d}: |acc|max = {acc_peaks[l]:.3e}"
              f"  ({'OK' if acc_peaks[l] < abs(q.ACC_MIN) else '溢出!'})")

    err = dv_x - dv_f
    abs_err = np.abs(err)
    rel_err = abs_err / np.abs(dv_f)
    p99 = np.percentile(abs_err, 99)
    p999 = np.percentile(abs_err, 99.9)
    print("\n=== 3. ΔV 部署误差（定点 - 浮点） ===")
    print(f"    ΔV 范围: [{dv_f.min():.1f}, {dv_f.max():.1f}] m/s")
    print(f"    绝对误差: mean={abs_err.mean():.4f}  std={abs_err.std():.4f}  "
          f"max={abs_err.max():.4f} m/s")
    print(f"    分位数:   p99={p99:.4f}  p99.9={p999:.4f} m/s")
    print(f"    相对误差: mean={rel_err.mean():.3e}  max={rel_err.max():.3e}")
    imax = int(np.argmax(abs_err))
    print(f"    最差样本 #{imax}: ΔV_float={dv_f[imax]:.2f}  "
          f"ΔV_fixed={dv_x[imax]:.2f}  err={err[imax]:+.4f} m/s")

    print("\n=== 4. 验收 ===")
    ok_p999 = p999 <= P999_LIMIT
    ok_max = abs_err.max() <= MAX_LIMIT
    ok_sat = worst <= 1e-3
    print(f"    p99.9 ≤ {P999_LIMIT} m/s : {p999:.4f}  {'PASS' if ok_p999 else 'FAIL'}")
    print(f"    max   ≤ {MAX_LIMIT} m/s : {abs_err.max():.4f}  {'PASS' if ok_max else 'FAIL'}")
    print(f"    饱和率 ≤ 0.1%        : {worst:.3e}  {'PASS' if ok_sat else 'FAIL'}")
    print(f"    总评: {'PASS — 权重 int16 + 激活 18bit 逐层定标方案可行' if (ok_p999 and ok_max and ok_sat) else 'FAIL — 需调参或升位宽'}")


if __name__ == "__main__":
    main()
