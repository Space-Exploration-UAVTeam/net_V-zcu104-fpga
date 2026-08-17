"""
qformat_experiment.py — Q 格式统一化对比实验（回答老师疑问用）
================================================================

问题：当前逐层 Q 格式（激活 frac=12/10/7/5/4/5、权重 frac=15/15/14/14/15/14/15）
是否太复杂？能否统一？本脚本用数据回答：不动 RTL，只在 golden model 侧
替换 cfg.Q_FORMAT（内存中 monkey-patch，跑完恢复，不落盘改 config），
复用 fixed_point_stats 的采样与统计路径（同 seed、同 2 万组包络样本），
对比各候选格式的部署误差与饱和率。

不变约束（所有变体一致）：权重 int16、激活 int18、输入 Q6.10、
ELU LUT 256 档（低 frac 层自动降档精确查表）、40bit 累加器；
CUT_POS = acc_frac - act_frac 随各层 frac 联动重算（build_fixed_cache 内自动）。

变体：
  base        基线（逐层定稿）——复跑确认，应复现 p99.9≈1.437 / max≈3.16
  uni_f4      统一激活 frac=4（Q14.4），权重统一 frac=14 —— "最统一"方案
  uni_f5      统一激活 frac=5（Q13.5），权重统一 frac=14
              （layer_05 浮点峰值 4051.7 接近量程边 4096，重点观察正支饱和率）
  tier_10_4   两档折中：layer_01~02 激活 frac=10，layer_03~06 frac=4，
              权重统一 frac=14
  uni_f4_wPL  消融：激活统一 frac=4 + 权重保持逐层 —— 分离权重统一的代价
  tier_wPL    消融：两档激活 10/4 + 权重保持逐层 —— 分离激活降档的代价
  uni_w14     消融：权重统一 frac=14 + 激活保持逐层 —— 最小幅度统一

验收线（与 fixed_point_stats 一致）：p99.9 ≤ 1.5 m/s 且 max ≤ 5 m/s，
单层正支饱和率 ≤ 0.1%。

运行：
    cd RL_project
    python3 scripts/qformat_experiment.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "scripts"))

import copy
import numpy as np
import config.model_config as cfg
from golden_model import network, quantize as q
from fixed_point_stats import (sample_inputs, forward_float_batch,
                               SEED, N_SAMPLES, CHUNK, P999_LIMIT, MAX_LIMIT)

SAT_RATE_LIMIT = 1e-3        # 单层正支饱和率阈值 0.1%

WF_BASE = {1: 15, 2: 15, 3: 14, 4: 14, 5: 15, 6: 14, 7: 15}
AF_BASE = {1: 12, 2: 10, 3: 7, 4: 5, 5: 4, 6: 5}
WF_UNI14 = {l: 14 for l in range(1, 8)}

VARIANTS = [
    ("base",      "基线：逐层定稿（wf 15/15/14/14/15/14/15，af 12/10/7/5/4/5）",
     WF_BASE,  AF_BASE),
    ("uni_f4",    "统一：激活全 frac=4，权重全 frac=14",
     WF_UNI14,  {l: 4 for l in range(1, 7)}),
    ("uni_f5",    "统一：激活全 frac=5，权重全 frac=14",
     WF_UNI14,  {l: 5 for l in range(1, 7)}),
    ("tier_10_4", "两档：激活 10/10/4/4/4/4，权重全 frac=14",
     WF_UNI14,  {1: 10, 2: 10, 3: 4, 4: 4, 5: 4, 6: 4}),
    ("uni_f4_wPL", "消融：激活全 frac=4，权重保持逐层",
     WF_BASE,   {l: 4 for l in range(1, 7)}),
    ("tier_wPL",  "消融：激活两档 10/4，权重保持逐层",
     WF_BASE,   {1: 10, 2: 10, 3: 4, 4: 4, 5: 4, 6: 4}),
    ("uni_w14",   "消融：权重统一 frac=14，激活保持逐层（最小幅度的统一）",
     WF_UNI14,  AF_BASE),
]


def run_variant(name, wf, af, x_q, dv_f):
    """替换 Q_FORMAT 跑一遍 2 万样本统计，返回结果 dict（随后恢复原配置）。"""
    orig = cfg.Q_FORMAT
    cfg.Q_FORMAT = copy.deepcopy(orig)
    cfg.Q_FORMAT["weight_frac"] = dict(wf)
    cfg.Q_FORMAT["act_frac"] = dict(af)
    try:
        cache = network.build_fixed_cache()
        dv_x = np.empty(N_SAMPLES)
        sat_counts, acc_peaks = {}, {}
        for s in range(0, N_SAMPLES, CHUNK):
            t = slice(s, s + CHUNK)
            acc7 = network.forward_network_fixed_batch(
                x_q[t], cache=cache, sat_counts=sat_counts, acc_peaks=acc_peaks)
            dv_x[t] = network.dequantize_dv(acc7, cache)
    finally:
        cfg.Q_FORMAT = orig

    abs_err = np.abs(dv_x - dv_f)
    # 各层饱和率（分母 = 样本数 × 该层神经元数）
    sat = {}
    worst_pos = 0.0
    for l in sorted(sat_counts):
        pos, neg = sat_counts[l]
        denom = N_SAMPLES * cfg.LAYERS[l - 1][1]
        sat[l] = (pos, pos / denom, neg, neg / denom)
        worst_pos = max(worst_pos, pos / denom)
    return {
        "name": name, "cache": cache,
        "mean": float(abs_err.mean()), "std": float(abs_err.std()),
        "p99": float(np.percentile(abs_err, 99)),
        "p999": float(np.percentile(abs_err, 99.9)),
        "max": float(abs_err.max()),
        "rel_mean": float((abs_err / np.abs(dv_f)).mean()),
        "sat": sat, "worst_pos": worst_pos, "acc_peaks": acc_peaks,
        "pass": (np.percentile(abs_err, 99.9) <= P999_LIMIT
                 and abs_err.max() <= MAX_LIMIT and worst_pos <= SAT_RATE_LIMIT),
    }


def print_variant(r, wf, af, desc):
    print("=" * 74)
    print(f"变体 {r['name']}: {desc}")
    print(f"  权重 frac: {[wf[l] for l in range(1, 8)]}   "
          f"激活 frac: {[af[l] for l in range(1, 7)]}")
    cp = [r["cache"][l]["cut_pos"] for l in range(1, 7)]
    print(f"  联动 CUT_POS(层1~6): {cp}   acc_frac7="
          f"{r['cache'][7]['acc_frac']}（ΔV 刻度 2^-{r['cache'][7]['acc_frac']}）")
    print("  各层再量化饱和（正支=有害 / 负支=无害）：")
    for l in sorted(r["sat"]):
        pos, pr, neg, nr = r["sat"][l]
        peak_real = r["acc_peaks"][l] / (2.0 ** r["cache"][l]["acc_frac"])
        print(f"    layer_{l:02d}: 正支 {pos:7d} ({pr:.3e})   "
              f"负支 {neg:8d} ({nr:.3e})   |acc|峰值实数≈{peak_real:.1f}")
    print(f"  ΔV 误差: mean={r['mean']:.4f}  std={r['std']:.4f}  "
          f"p99={r['p99']:.4f}  p99.9={r['p999']:.4f}  max={r['max']:.4f} m/s")
    print(f"  相对误差 mean={r['rel_mean']:.3e}   最大单层正支饱和率 "
          f"{r['worst_pos']:.3e}（阈值 {SAT_RATE_LIMIT:.0e}）")
    verdict = []
    verdict.append("p99.9≤1.5 " + ("PASS" if r["p999"] <= P999_LIMIT
                                   else f"FAIL({r['p999']:.3f})"))
    verdict.append("max≤5 " + ("PASS" if r["max"] <= MAX_LIMIT
                               else f"FAIL({r['max']:.3f})"))
    verdict.append("饱和率≤0.1% " + ("PASS" if r["worst_pos"] <= SAT_RATE_LIMIT
                                     else f"FAIL({r['worst_pos']:.2e})"))
    print(f"  验收: {'; '.join(verdict)} => 总评 "
          f"{'PASS' if r['pass'] else 'FAIL'}")


def main():
    print(f">>> 采样 {N_SAMPLES} 组包络输入（seed={SEED}，与 fixed_point_stats "
          f"基线完全同源）...")
    X = sample_inputs(N_SAMPLES, SEED)
    Z = network.normalize_input(X)
    x_q = q.quantize_to(Z, cfg.Q_FORMAT["input_frac"],
                        bits=cfg.Q_FORMAT["input_bits"])
    print(f"    归一化输入范围 [{Z.min():.3f}, {Z.max():.3f}]；"
          f"输入量化 Q6.10 int16（所有变体共用）")

    print(">>> 浮点参考（float64 txt 权重全链，所有变体共用一份）...")
    cache_f = network.load_network_cache_float()
    dv_f = np.empty(N_SAMPLES)
    for s in range(0, N_SAMPLES, CHUNK):
        dv_f[slice(s, s + CHUNK)] = forward_float_batch(
            Z[slice(s, s + CHUNK)], cache_f)
    print(f"    ΔV 浮点范围 [{dv_f.min():.1f}, {dv_f.max():.1f}] m/s")

    results = []
    for name, desc, wf, af in VARIANTS:
        print(f">>> 跑变体 {name} ...")
        r = run_variant(name, wf, af, x_q, dv_f)
        print_variant(r, wf, af, desc)
        results.append(r)

    print("\n" + "=" * 74)
    print("汇总表（2 万样本，定点 vs 浮点 ΔV 绝对误差，单位 m/s）：")
    print(f"{'变体':<11} {'mean':>8} {'p99':>8} {'p99.9':>8} {'max':>8} "
          f"{'正支饱和':>10} {'总评':>6}")
    for r in results:
        print(f"{r['name']:<11} {r['mean']:8.4f} {r['p99']:8.4f} "
              f"{r['p999']:8.4f} {r['max']:8.4f} {r['worst_pos']:10.2e} "
              f"{'PASS' if r['pass'] else 'FAIL':>6}")
    base = results[0]
    print(f"\n相对基线的代价（Δp99.9 / Δmax，m/s）：")
    for r in results[1:]:
        print(f"  {r['name']:<11} p99.9 {base['p999']:.3f}→{r['p999']:.3f} "
              f"(+{r['p999']-base['p999']:.3f})   "
              f"max {base['max']:.3f}→{r['max']:.3f} "
              f"(+{r['max']-base['max']:.3f})")


if __name__ == "__main__":
    main()
