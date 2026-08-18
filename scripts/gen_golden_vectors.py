"""
gen_golden_vectors.py — 生成 RTL testbench 用的 golden 向量(阶段 3)
======================================================================

用 golden model 的 bit-true 定点路径(network.forward_network_fixed, 与
tests/test_bit_true.py 同一条已验证链路)生成 testbench 激励与期望。

造 27 组输入:1 组交付样本 + 10 组包络内随机（seed 固定）+ 16 组边界（min/max 组合）;
跑 golden model 定点路径，算出每组的全链定点结果（40bit acc7）和逐层 512 个激活；
导出成 hex 文件(inputs/expected/acts_s00~s26)——这些是 testbench 的"标准答案",RTL 仿真拿它们逐 bit 比对。
一句话：它是连接"Python 参考模型"和"Verilog 验证"的桥——没有它，testbench 不知道正确答案是什么。

样本(27 组 = 1 典型 + 10 随机 + 16 边界): 
  - s00 sample_00        : 交付典型样本(data/test_samples/)
  - s01~s10 rand_00~09   : 包络均匀随机(fixed_point_stats.sample_inputs, 
                           seed=777 独立流, 与上一版一致)
  - s11 bnd_all_min      : 边界-全 min(7 维全部取下界)
  - s12 bnd_all_max      : 边界-全 max
  - s13~s19 bnd_<dim>_max: 边界-单维 max(该维取上界, 其余 6 维取下界)
  - s20~s26 bnd_<dim>_min: 边界-单维 min(该维取下界, 其余取上界)
  7 维特征顺序(与归一化文件一致): h0[400,800]、I0[1.0472,1.3963]、
  Δh(=hf-h0)[-400,400]、ΔI[0,0.087266]、ΔΩ[-3.1416,0]、fmax[5e-4,5e-3]、
  tf[0,3.1536e7]。
  注: Δh 边界与 hf/h0∈[400,800] 自洽(max=800-400=400, min=-400)。
  边界角点可能超出物理可达域(如 h0=800 且 Δh=400 → hf=1200), 这正是
  压力测试意图；若触发再量化饱和/累加器抬升, 属设计信息, 脚本会统计报告。

产物(写到 data/vectors/): 
  inputs.hex    — 27 行, 每行 7 个 int16 补码 hex(空格分隔), Q6.10 量化输入。
                  testbench $readmemh 到 27×7 个 16bit 字, 每样本取 7 个。
  expected.hex  — 27 行, 每行 1 个 40bit 补码 hex: layer_07 累加器原值
                  (acc7, 含 bias, 不截位不过 ELU；ΔV = acc7 × 2^-20)。
  ref.txt       — 人类可读参考: 类别标注、原始/归一化/量化输入、acc7 十进制、
                  定点/浮点 ΔV、逐层饱和计数与累加器峰值(排查用, 不参与比对)。
  acts_sXX.hex  — 每样本一个文件: layer_01~06 的逐层激活期望(int18 补码, 
                  每层 512 行, 共 3072 行), 供分层 debug / net_v_layers_tb
                  逐 bit 比对。

自检: 每个样本用 forward_network_fixed 独立复算 acc7, 与逐层 trace 的
      结果比对一致才落盘；并检查各层累加器峰值是否逼近 40bit 上限 2^39。

运行: 
    cd RL_project
    python3 scripts/gen_golden_vectors.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "scripts"))

import numpy as np
import config.model_config as cfg
from golden_model import network, quantize as q, reader
from fixed_point_stats import sample_inputs

OUT_DIR = os.path.join(cfg._PROJ_ROOT, "data", "vectors")
RANDOM_SEED = 777
N_RANDOM = 10

# 7 维特征包络(顺序 = 归一化文件 feature_01..07)
DIM_NAMES = ["h0", "I0", "dH", "dI", "dO", "fmax", "tf"]
BOUNDS = [
    (400.0, 800.0),        # h0 (km)
    (1.0472, 1.3963),      # I0 (rad)
    (-400.0, 400.0),       # Δh = hf - h0 (km), 与 hf/h0∈[400,800] 自洽
    (0.0, 0.087266),       # ΔI = If - I0 (rad)
    (-3.1416, 0.0),        # ΔΩ = ωf - ω0 (rad)
    (5e-4, 5e-3),          # fmax (m/s^2)
    (0.0, 3.1536e7),       # tf (s)
]

ACC_LIMIT = 1 << 39        # 40bit 有符号累加器上限 |acc| < 2^39


def sext_hex(v, bits):
    """有符号整数 → 补码 hex。"""
    return format(int(v) & ((1 << bits) - 1), "0{}x".format(bits // 4))


def make_boundary_samples():
    """构造 16 组边界样本, 返回 [(name, category, x_raw_7d), ...]。"""
    lo = np.array([b[0] for b in BOUNDS])
    hi = np.array([b[1] for b in BOUNDS])
    out = [("bnd_all_min", "边界-全min", lo.copy()),
           ("bnd_all_max", "边界-全max", hi.copy())]
    for k in range(7):     # 单维拉 max, 其余 min
        v = lo.copy()
        v[k] = hi[k]
        out.append(("bnd_{}_max".format(DIM_NAMES[k]),
                    "边界-{}_max".format(DIM_NAMES[k]), v))
    for k in range(7):     # 单维拉 min, 其余 max
        v = hi.copy()
        v[k] = lo[k]
        out.append(("bnd_{}_min".format(DIM_NAMES[k]),
                    "边界-{}_min".format(DIM_NAMES[k]), v))
    return out


def forward_fixed_traced(x_q, cache):
    """bit-true 逐层 trace + 边界分析。

    返回 (acc7, acts, stats): 
        acc7  : layer_07 累加器原值(语义与 forward_network_fixed 一致, 
                main 里逐样本断言复核)
        acts  : [layer_01..06 激活], 每个 (512,) int
        stats : {层号(1..6): {"pos","neg","peak"}}, pos/neg = 再量化后
                正/负支饱和次数(语义同 network.fixed_layer 的 sat_counter；
                负支对 ELU 无害——见 fixed_point_spec.md §4 注), 
                peak = 该层 40bit 累加器 |acc| 峰值
    """
    acts, stats = [], {}
    x = np.asarray(x_q, dtype=np.int64)
    for layer_no in sorted(cache):
        e = cache[layer_no]
        acc = e["W"] @ x + e["b"]            # int64 模拟 40bit 累加器
        if e["act"] == "linear":
            return int(acc[0]), acts, stats
        # 统计用中间值(round_shift 同 quantize 原语；饱和语义与
        # network.fixed_layer 的 sat_counter 一致)
        y = q.round_shift(acc, e["cut_pos"])
        hi = (1 << (e["bits"] - 1)) - 1
        lo = -(1 << (e["bits"] - 1))
        stats[layer_no] = {
            "pos": int(np.count_nonzero(y > hi)),
            "neg": int(np.count_nonzero(y < lo)),
            "peak": int(np.abs(acc).max()),
        }
        x = network.fixed_layer(acc, e)      # 再量化+饱和+ELU LUT(同源函数)
        acts.append(x.copy())
    raise RuntimeError("网络没有线性输出层")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # --v2 <param_dir>：切到 v2 .npy 数据源（默认 v1 txt 行为不变）
    argv = sys.argv[1:]
    if "--v2" in argv:
        reader.set_source_v2(argv[argv.index("--v2") + 1])
        print(">>> 数据源：v2 npy（{}）".format(reader.source_name()))
    else:
        print(">>> 数据源：v1 txt（默认）")

    cache = network.build_fixed_cache()
    cache_f = network.load_network_cache_float()

    # ---- 收集样本: sample_00 + 随机 + 边界 ----
    samples = [("sample_00", "典型", np.asarray(reader.read_test_input(),
                                                 dtype=np.float64))]
    X_rand = sample_inputs(N_RANDOM, RANDOM_SEED)
    for i in range(N_RANDOM):
        samples.append(("rand_{:02d}".format(i), "随机",
                        np.asarray(X_rand[i], dtype=np.float64)))
    samples.extend(make_boundary_samples())
    assert len(samples) == 27

    in_lines, exp_lines = [], []
    ref = ["# golden 向量参考(gen_golden_vectors.py 生成)",
           "# 27 样本 = sample_00(典型) + 10 随机(seed=777) + 16 边界",
           "# acc7 为 layer_07 的 40bit 累加器原值, ΔV = acc7 × 2^-20",
           "# 饱和计数: pos=正支钳位(设计上不应发生, >0 需关注)；",
           "#           neg=负支钳位(对 ELU 无害, 见 fixed_point_spec §4 注)",
           ""]
    anomalies = []          # (样本标签, 描述) 汇总到末尾

    print("样本  类别/名称            acc7              ΔV(m/s)      备注")
    for si, (name, cat, x_raw) in enumerate(samples):
        z = network.normalize_input(x_raw)
        x_q = q.quantize_to(z, cfg.Q_FORMAT["input_frac"],
                            cfg.Q_FORMAT["input_bits"])
        assert x_q.shape == (7,)
        if not np.all(np.abs(x_q) < 32768):
            anomalies.append((si, name, "输入量化触到 int16 饱和: {}"
                              .format(x_q.tolist())))

        # bit-true 定点(逐层 trace + 独立复算交叉自检)
        acc7, acts, stats = forward_fixed_traced(x_q, cache)
        acc7_chk = network.forward_network_fixed(x_q, cache)
        assert acc7 == acc7_chk, "{}: trace 与 forward_network_fixed 不一致" \
                                 .format(name)
        assert len(acts) == 6 and all(a.shape == (512,) for a in acts)
        if abs(acc7) >= ACC_LIMIT:
            anomalies.append((si, name, "acc7 超出 40bit！"))

        # 浮点参考(txt 权重 float64 全链)
        dv_float = float(network.forward_network_float_traced(z, cache_f)[0][0])
        dv_fixed = float(network.dequantize_dv(acc7, cache))

        in_lines.append(" ".join(sext_hex(v, 16) for v in x_q))
        exp_lines.append(sext_hex(acc7, 40))

        with open(os.path.join(OUT_DIR, "acts_s{:02d}.hex".format(si)),
                  "w") as fp:
            for a in acts:
                for v in a:
                    fp.write(sext_hex(v, 18) + "\n")

        # ---- 边界分析汇总 ----
        sat_msg = []
        for l in sorted(stats):
            st = stats[l]
            if st["pos"] > 0:
                sat_msg.append("layer_{:02d} 正支饱和 {} 次(有害!)".format(
                    l, st["pos"]))
                anomalies.append((si, name,
                                  "layer_{:02d} 正支饱和 {} 次".format(l,
                                                                  st["pos"])))
            elif st["neg"] > 0:
                sat_msg.append("layer_{:02d} 负支饱和 {} 次(无害)".format(
                    l, st["neg"]))
            if st["peak"] >= ACC_LIMIT:
                anomalies.append((si, name,
                                  "layer_{:02d} 累加器峰值 {:.3e} ≥ 2^39！".format(
                                      l, float(st["peak"]))))
        peak_max = max(st["peak"] for st in stats.values())
        peak_msg = "acc峰值 {:.2e} (2^{:.1f})".format(
            float(peak_max), np.log2(max(peak_max, 1)))

        ref.append("--- s{:02d} {} [{}] ---".format(si, name, cat))
        ref.append("raw      : " + " ".join("{:.6g}".format(v) for v in x_raw))
        ref.append("norm     : " + " ".join("{:.6f}".format(v) for v in z))
        ref.append("x_q      : " + " ".join(str(int(v)) for v in x_q))
        ref.append("acc7     : {}  (hex {})".format(acc7, sext_hex(acc7, 40)))
        ref.append("ΔV_fixed : {:.6f} m/s".format(dv_fixed))
        ref.append("ΔV_float : {:.6f} m/s   err={:+.6f} m/s".format(
            dv_float, dv_fixed - dv_float))
        ref.append("饱和统计 : " + ("；".join(sat_msg) if sat_msg else "无"))
        ref.append("累加器   : " + peak_msg)
        ref.append("")

        print("s{:02d}   {}/{}  {:>14d}  {:>12.4f}  {}".format(
            si, cat, name, acc7, dv_fixed,
            "；".join(sat_msg) if sat_msg else ""))

    with open(os.path.join(OUT_DIR, "inputs.hex"), "w") as fp:
        fp.write("\n".join(in_lines) + "\n")
    with open(os.path.join(OUT_DIR, "expected.hex"), "w") as fp:
        fp.write("\n".join(exp_lines) + "\n")

    # ---- 异常汇总 ----
    ref.append("=" * 60)
    if anomalies:
        ref.append("异常/设计信息汇总({} 条): ".format(len(anomalies)))
        for si, name, msg in anomalies:
            ref.append("  s{:02d} {}: {}".format(si, name, msg))
    else:
        ref.append("异常汇总: 无(无正支饱和、无 40bit 溢出风险、输入未触饱和)")
    with open(os.path.join(OUT_DIR, "ref.txt"), "w") as fp:
        fp.write("\n".join(ref) + "\n")

    print("\n=== 已生成 {} 个样本到 data/vectors/ ===".format(len(samples)))
    print("  inputs.hex   : {} 行 × 7 字(Q6.10 int16)".format(len(in_lines)))
    print("  expected.hex : {} 行(40bit acc7)".format(len(exp_lines)))
    print("  acts_s00~s26.hex : 每样本 6 层 × 512 行 int18(分层 tb 用)")
    print("  ref.txt      : 类别标注 + 浮点 ΔV + 饱和/峰值统计")
    if anomalies:
        print("\n!!! 异常/设计信息({} 条, 详见 ref.txt 末尾): ".format(
            len(anomalies)))
        for si, name, msg in anomalies:
            print("  s{:02d} {}: {}".format(si, name, msg))
    else:
        print("\n异常汇总: 无(无正支饱和、无 40bit 溢出风险、输入未触饱和)")


if __name__ == "__main__":
    main()
