# data/vectors — RTL testbench golden 向量

由 `scripts/gen_golden_vectors.py` 生成（golden model bit-true 定点路径，
与 `tests/test_bit_true.py` 同一条已验证链路）。

## 样本（27 组）

| 编号 | 名称 | 类别 |
|---|---|---|
| s00 | sample_00 | 典型（交付样本） |
| s01~s10 | rand_00~09 | 随机包络（`fixed_point_stats.sample_inputs`，seed=777） |
| s11 | bnd_all_min | 边界-全 min（7 维全部下界） |
| s12 | bnd_all_max | 边界-全 max |
| s13~s19 | bnd_{h0,I0,dH,dI,dO,fmax,tf}_max | 边界-单维 max（该维上界，其余下界） |
| s20~s26 | bnd_{h0,I0,dH,dI,dO,fmax,tf}_min | 边界-单维 min（该维下界，其余上界） |

7 维特征包络：h0[400,800]、I0[1.0472,1.3963]、Δh[-400,400]（=hf-h0，
与 hf/h0∈[400,800] 自洽）、ΔI[0,0.087266]、ΔΩ[-3.1416,0]、
fmax[5e-4,5e-3]、tf[0,3.1536e7]。

## 文件

- `inputs.hex` — 27 行，每行 7 个 int16 补码 hex（空格分隔）：
  归一化输入按 Q6.10 量化（规则①），testbench $readmemh 到 27×7 个 16bit 字。
- `expected.hex` — 27 行，每行 1 个 40bit 补码 hex：layer_07 累加器原值
  acc7（含 bias，不截位不过 ELU）。**net_v_top_tb 零容差逐 bit 比对这个。**
  ΔV = acc7 × 2^-20。
- `acts_s00.hex ~ acts_s26.hex` — 每样本 3072 行：layer_01~06 逐层激活期望
  （int18 补码，每层 512 行连续存放）。**net_v_layers_tb 分层逐 bit 比对
  这个**（层次引用监视 `dut.u_engine` 的 layer_idx/ping/act_buf）；
  **net_v_layer_debug_tb 单层独立验证也用这个**（第 k 层输入 = 第 k-1 层
  输出 = 第 (k-2)*512..(k-1)*512-1 行）。
- `ref.txt` — 人类可读参考：类别标注、原始/归一化/量化输入、acc7 十进制、
  定点/浮点 ΔV、逐层饱和计数与累加器峰值（排查用，不参与比对）。
- `sim_top.log` / `sim_layers.log` — 两个 testbench 的 iverilog 仿真日志
  （当前均为 ALL PASS）。
- `sim_layer_debug.log` — 单层调试 tb 的 12 组验证矩阵日志（全 PASS）。

## 单层独立调试（net_v_layer_debug_tb）

定位到"样本 s 第 k 层"出错后，单独复跑该层：把第 k-1 层输出灌进 DUT
激活 buffer，poke FSM 从第 k 层起跑，只比这一层（原理与用法详见
`rtl/tb/net_v_layer_debug_tb.v` 头注释）。

```
# iverilog（工作目录 = RL_project）
iverilog -g2005 -s net_v_layer_debug_tb -o /tmp/dbg \
    rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v \
    rtl/net_v_top.v rtl/tb/net_v_layer_debug_tb.v
vvp /tmp/dbg +SAMPLE=0 +LAYER=3     # 缺省 SAMPLE=0 LAYER=1

# XSim 2018.3：plusargs 用 -testplusarg 逐个给
xsim work.net_v_layer_debug_tb -testplusarg "SAMPLE=0" -testplusarg "LAYER=3"
```

k=1 输入取 `inputs.hex` 第 s 行；k=2..6 输入取 `acts_sXX.hex` 第 k-1 层
输出段；k=7（输出层）比 `expected.hex` 第 s 个 40bit acc7。

## 结论性统计（生成时自检，详见 ref.txt 末尾）

- 27 样本无任何正支（有害）饱和；负支饱和仅出现在 layer_06
  （对 ELU 无害，fixed_point_spec §4 注），单样本最多 18 次/512 神经元
- 全部样本各层累加器峰值 ≤ 1.01e10 ≈ 2^33.2，距 40bit 上限 2^39 有 5.8 bit 余量
- 输入量化均未触 int16 饱和
