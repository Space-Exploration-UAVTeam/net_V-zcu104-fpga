"""
gen_hex.py — 生成 RTL ROM 初始化 hex 文件（阶段 3）
====================================================

从 golden model 的 bit-true 定点缓存（network.build_fixed_cache）和
ELU LUT 生成器（elu_lut.build_elu_lut）导出 $readmemh 用的 hex 文件，
保证 Python golden model 与 RTL 用的是**同一份数值**（语义见
docs/fixed_point_spec.md，本脚本不引入任何新规则）。

产物（写到 data/hex/）：
  1. weights_all.hex — 全部 7 层权重打包成 256bit 字，每行 64 个 hex 字符
       打包格式（与 rtl/weight_rom.v / fc_engine.v 的约定一致）：
         - 一个字 = 16 条 lane 的 int16 权重：bit[16k+15:16k] = lane k
         - lane k 对应输入元素 a[16*t + k]（t = 组号，0 起）
         - 地址 = w_base[layer] + 神经元号 j × 每组字数 NG + 组号 t
           （"输出神经元连续"：同一神经元的 NG 个字地址连续）
         - NG = ceil(in_dim/16)：layer_01 为 1（7 输入，lane 7..15 补 0），
           其余层为 32（512 输入）。补 0 方式：权重 lane 补 0（RTL 侧
           输入装载也把 act_buf[7..15] 清 0，双保险，见 fc_engine.v 注释）
       层地址基址 w_base（生成后打印，RTL 参数表照抄）：
         layer_01=0, layer_02=512, ..., 总字数 82464
  2. bias_all.hex — 全部 bias，40bit 字（acc_frac 刻度，规则①量化），
       每行 10 个 hex 字符；地址 = b_base[layer] + j。共 3073 行。
  3. elu_lut.hex — 5 张去重 ELU 负支表（f = 12,10,7,5,4；layer_04/06 同 f=5
       共享），每行 4 个 hex 字符（int16 补码），共 1157 行。
       基址：f12=0, f10=257, f7=514, f5=771, f4=1028。

自检：生成后把 hex 重新解析回整数，与 golden model 缓存逐值比对，
      任何一个不一致就报错退出（防止打包/补码/顺序写错）。

运行：
    cd RL_project
    python3 scripts/gen_hex.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import config.model_config as cfg
from golden_model import network, elu_lut

OUT_DIR = os.path.join(cfg._PROJ_ROOT, "data", "hex")

LANES = 16                    # 每拍 16 路输入并行
W_WORD_BITS = LANES * 16      # 256bit
ACC_BITS = 40                 # bias 字宽（与 quantize.ACC_BITS 一致）

# 逐层表参数（与 fc_engine.v 的 LPT 参数表必须一致；脚本会打印核对）
# 顺序：f = 12, 10, 7, 5, 4（layer_04 与 layer_06 都是 f=5，共享一张表）
ELU_TABLE_FRACS = [12, 10, 7, 5, 4]


def to_hex(value, bits):
    """有符号整数 → 补码 hex 字符串（长度 bits/4）。"""
    mask = (1 << bits) - 1
    v = int(value) & mask
    return format(v, "0{}x".format(bits // 4))


def gen_weight_words(cache):
    """生成权重字列表 + 每层基址。

    返回 (words, w_bases)：
        words   : list[int]，每个元素是一个 256bit 字（整数）
        w_bases : {layer_no: 基址}
    """
    words = []
    w_bases = {}
    for layer_no, (in_dim, out_dim, _act) in enumerate(cfg.LAYERS, start=1):
        e = cache[layer_no]
        W_q = e["W"]                       # (out, in) int16 定点
        assert W_q.shape == (out_dim, in_dim), \
            f"layer_{layer_no} 权重形状 {W_q.shape} != ({out_dim},{in_dim})"
        ng = (in_dim + LANES - 1) // LANES  # 每神经元的字数（组数）
        w_bases[layer_no] = len(words)
        for j in range(out_dim):
            for t in range(ng):
                word = 0
                for k in range(LANES):
                    i = t * LANES + k
                    # 越界 lane 补 0（只有 layer_01 的 7..15 会触发）
                    w = int(W_q[j, i]) if i < in_dim else 0
                    assert -32768 <= w <= 32767, "权重建外 int16"
                    word |= (w & 0xFFFF) << (16 * k)
                words.append(word)
    return words, w_bases


def gen_bias_words(cache):
    """生成 bias 字列表 + 每层基址（40bit，acc_frac 刻度）。"""
    words = []
    b_bases = {}
    for layer_no, (_in, out_dim, _act) in enumerate(cfg.LAYERS, start=1):
        b_q = cache[layer_no]["b"]
        assert b_q.shape == (out_dim,)
        b_bases[layer_no] = len(words)
        for j in range(out_dim):
            v = int(b_q[j])
            assert -(1 << 39) <= v < (1 << 39), "bias 超出 40bit"
            words.append(v)
    return words, b_bases


def gen_elu_tables():
    """生成 5 张去重 ELU 表 + 每个 frac 的基址（与 elu_lut.build_elu_lut 同源）。"""
    vals = []
    bases = {}
    for f in ELU_TABLE_FRACS:
        lut = elu_lut.build_elu_lut(f, cfg.ELU_LUT_N, cfg.ELU_NEG_RANGE)
        bases[f] = len(vals)
        vals.extend(int(v) for v in lut["table"])
    return vals, bases


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    cache = network.build_fixed_cache()

    # ---- 1. 权重 ----
    w_words, w_bases = gen_weight_words(cache)
    w_path = os.path.join(OUT_DIR, "weights_all.hex")
    with open(w_path, "w") as fp:
        for w in w_words:
            fp.write(format(w, "064x") + "\n")
    print(f"[权重] {w_path}")
    print(f"       总字数 {len(w_words)}（256bit/字，"
          f"{len(w_words) * W_WORD_BITS / 8 / 1024:.0f} KiB）")
    for l in sorted(w_bases):
        print(f"       layer_{l:02d} w_base = {w_bases[l]}")

    # ---- 2. bias ----
    b_words, b_bases = gen_bias_words(cache)
    b_path = os.path.join(OUT_DIR, "bias_all.hex")
    with open(b_path, "w") as fp:
        for v in b_words:
            fp.write(to_hex(v, ACC_BITS) + "\n")
    print(f"[bias] {b_path}  共 {len(b_words)} 行（40bit）")
    for l in sorted(b_bases):
        print(f"       layer_{l:02d} b_base = {b_bases[l]}")

    # ---- 3. ELU LUT ----
    elu_vals, elu_bases = gen_elu_tables()
    e_path = os.path.join(OUT_DIR, "elu_lut.hex")
    with open(e_path, "w") as fp:
        for v in elu_vals:
            fp.write(to_hex(v, 16) + "\n")
    print(f"[ELU ] {e_path}  共 {len(elu_vals)} 行（int16）")
    for f in ELU_TABLE_FRACS:
        print(f"       f={f:2d} lut_base = {elu_bases[f]}")

    # ---- 自检：把 hex 解析回去逐值比对 ----
    print(">>> 自检：回读 hex 与 golden model 缓存比对...")
    # 权重
    back = [int(line.strip(), 16) for line in open(w_path) if line.strip()]
    assert len(back) == len(w_words), "权重行数不符"
    assert back == w_words, "权重 hex 回读不一致"
    # 逐 lane 抽查数值（含 layer_01 补 0 lane）
    for layer_no, (in_dim, out_dim, _a) in enumerate(cfg.LAYERS, start=1):
        ng = (in_dim + LANES - 1) // LANES
        W_q = cache[layer_no]["W"]
        for j in (0, out_dim // 2, out_dim - 1):           # 首/中/尾神经元
            for t in (0, ng - 1):                          # 首/末组
                word = back[w_bases[layer_no] + j * ng + t]
                for k in range(LANES):
                    i = t * LANES + k
                    lane = word >> (16 * k) & 0xFFFF
                    lane = lane - (1 << 16) if lane >= (1 << 15) else lane
                    exp = int(W_q[j, i]) if i < in_dim else 0
                    assert lane == exp, \
                        f"layer_{layer_no} j={j} t={t} lane{k}: {lane} != {exp}"
    print("       权重 256bit 打包（含 layer_01 补 0 lane）逐值抽查 PASS")
    # bias
    bback = [int(line.strip(), 16) for line in open(b_path) if line.strip()]
    bback = [v - (1 << 40) if v >= (1 << 39) else v for v in bback]
    assert bback == b_words, "bias hex 回读不一致"
    print("       bias 40bit 补码回读 PASS")
    # ELU
    eback = [int(line.strip(), 16) for line in open(e_path) if line.strip()]
    eback = [v - (1 << 16) if v >= (1 << 15) else v for v in eback]
    assert eback == elu_vals, "ELU hex 回读不一致"
    # 手算锚点（与 tests/test_bit_true.py 第 3 节一致）：f=12 表 T[255]=-126, T[256]=0
    f12 = elu_bases[12]
    assert eback[f12 + 255] == -126 and eback[f12 + 256] == 0, "f=12 表锚点错"
    print("       ELU 表回读 + f=12 手算锚点 PASS")

    print("\n=== gen_hex 完成：3 个 hex 已写入 data/hex/ ===")
    print("提示：w_base / b_base / lut_base 与 rtl/fc_engine.v 参数表必须一致，")
    print("      改 Q 格式或层结构时两个文件要同步改。")


if __name__ == "__main__":
    main()
