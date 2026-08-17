# RL_project — ZCU104 强化学习 FC 推理部署项目

轨道转移 ΔV 优化 RL 模型，部署到 **Xilinx ZCU104（XCZU7EV）** 做硬件推理。

- 激活函数：**ELU(α=1)**（隐藏层，真实模型 net_V 交付确认）；输出层 linear 无激活
- 目标板卡：**ZCU104 / XCZU7EV-2FFVC1156**（已定死）
- 开发工具：Vivado 2018.3 + SDK 2018.3

---

## 1. 项目需要哪些内容（全貌）

完整闭环：

```text
模型同学交付数据           ← 老师清单（架构/权重/测试样本/.pt）
   ↓
Python golden model        ← 本目录 golden_model/
   ↓
定点格式与量化规则          ← quantize.py + config（逐层 Q 格式定稿）
   ↓
RTL 计算核（16 路输入并行） ← rtl/
   ↓
自检 testbench + XSim      ← rtl/tb/（5 个 tb，逐 bit 零容差）
   ↓
综合/实现/时序              ← Vivado（WNS=+1.277ns @100MHz）
   ↓
ZCU104 PS/PL 接口           ← AXI-Lite（输入7维/输出1维，无需DMA）
   ↓
以太网协议（UDP）           ← lwIP（PS 端）
```

**当前进度**：✅ 全部完成（2026-08-15）——golden model、RTL、三重仿真、综合实现、
IP/BD、SDK、板上自检（逐 bit 一致）、以太网 UDP 联调 27/27 PASS。
总览见 `docs/项目总体介绍.md`。

---

## 2. 现在能实现的内容

| 文件 | 作用 | 状态 |
|---|---|---|
| `config/model_config.py` | 全网参数总表（层结构/Q格式定稿/并行度） | ✅ 已对齐真实结构 + Q 格式定稿 |
| `golden_model/reader.py` | 读模型同学的权重/bias/归一化/测试样本 | ✅ 可用（科学记数法解析） |
| `golden_model/quantize.py` | 定点量化原语（两种舍入/饱和/CUT_POS） | ✅ bit-true 语义已定死 |
| `golden_model/bn_fold.py` | BN 折叠进 FC 权重 | 真实模型无 BN，此路径不用 |
| `golden_model/layers.py` | 单层 FC+ELU/linear 前向（定点+浮点） | ✅ 可用 |
| `golden_model/elu_lut.py` | ELU LUT+线性插值（硬件方案 bit-true） | ✅ 可用，规格见 spec |
| `golden_model/network.py` | 7 层前向（浮点 + bit-true 定点） | ✅ 浮点/定点均与 golden 对齐 |
| `data/` 各子目录 | 模型数据落位 | ✅ 真实数据已落位（weights/biases/test_samples） |
| `tests/test_quantize.py` | 量化工具自检 | ✅ 可运行 |
| `tests/test_golden_model.py` | 端到端自检（量化+单层+全链路+真实数据逐层对比） | ✅ 27 项 PASS |
| `tests/test_elu.py` | ELU 激活边界自检 | ✅ 9 项 PASS |
| `tests/test_bit_true.py` | bit-true 定点路径自检（手算锚点 + sample_00） | ✅ 28 项 PASS |
| `scripts/fixed_point_stats.py` | 2 万样本部署误差统计验收 | ✅ p99.9=1.44 m/s 过线 |
| `scripts/qformat_experiment.py` | Q 格式统一化对比实验（回答老师疑问） | ✅ 结论：保持逐层，见 docs/qformat_experiment.md |
| `scripts/gen_hex.py` | 权重/bias/ELU LUT → ROM hex（带回读自检） | ✅ 已生成 data/hex/ |
| `scripts/gen_golden_vectors.py` | testbench golden 向量（27 样本 acc7 + 逐层激活 + 边界分析） | ✅ 已生成 data/vectors/ |
| `rtl/net_v_top.v` | 顶层：start/done 握手 + 7 输入寄存器 | ✅ 仿真 PASS |
| `rtl/fc_engine.v` | 层引擎：16 lane MAC + 加法树 + 后处理，7 层时分复用 | ✅ 仿真 PASS |
| `rtl/weight_rom.v` / `bias_rom.v` / `elu_lut.v` | ROM/查找表（$readmemh） | ✅ 仿真 PASS |
| `rtl/tb/net_v_top_tb.v` | 零容差逐 bit 比对 testbench（比 acc7） | ✅ 27/27 样本 ALL PASS |
| `rtl/tb/net_v_layers_tb.v` | 分层 testbench（逐层激活 6×512 比对） | ✅ 27 样本 × 6 层 ALL PASS |
| `rtl/tb/net_v_layer_debug_tb.v` | 单层独立调试 tb（plusargs 选样本/层，poke 启动） | ✅ 12 组验证矩阵 ALL PASS |
| `rtl/axi/net_v_axi.v` | AXI-Lite 外壳（寄存器映射 + 权重加载口） | ✅ 已封装上板 |
| `rtl/tb/net_v_axi_tb.v` | AXI 外壳自检（权重口/全链/软复位） | ✅ 12/12 ALL PASS |
| `sdk/src/main.c` | PS 裸机程序（权重加载+归一化+推理+lwIP UDP） | ✅ 板测通过 |
| `sdk/pc_client/udp_client.py` | PC 客户端（ping/sample/batch/run/selftest） | ✅ 27/27 PASS |
| `docs/fixed_point_spec.md` | 定点规格书（RTL 施工图纸） | ✅ 定稿 |

**验证：** 运行 `python3 tests/test_golden_model.py` 应输出 `全部 27 项检查 PASS`。
（含真实数据逐层对比：归一化 → 7 层浮点前向（ELU）vs 交付 golden vector，
逐层 max abs err ≤ 5e-2，误差来源是交付 txt 只保留 5 位有效数字。）
定点验收：运行 `python3 scripts/fixed_point_stats.py`，ΔV 部署误差
p99.9 = 1.44 m/s ≤ 1.5，max = 3.16 ≤ 5（方案：权重 int16 + 激活 18bit）。

**RTL 验收（阶段 3 已完成）**：先跑 `python3 scripts/gen_hex.py` 和
`python3 scripts/gen_golden_vectors.py` 生成 ROM/向量文件，再编译仿真
（工作目录 = RL_project）：

```
# 顶层 tb：27 样本 acc7 零容差逐 bit 比对
iverilog -g2005 -s net_v_top_tb -o /tmp/net_v_simv \
    rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v \
    rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_top_tb.v
vvp /tmp/net_v_simv        # 期望输出 ALL PASS（27/27 样本逐 bit 一致）

# 分层 tb：每样本 6 层 × 512 神经元激活逐 bit 比对（层次引用监视 DUT 内部）
iverilog -g2005 -s net_v_layers_tb -o /tmp/net_v_layers \
    rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v \
    rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_layers_tb.v
vvp /tmp/net_v_layers      # 期望输出 ALL PASS（27×6 层全比对）
```

参考日志：`data/vectors/sim_top.log` / `sim_layers.log`。

Vivado 2018.3 XSim：详细到每一步的操作见 `docs/testing_runbook.md`（手册版）。
要点：6 个 RTL + 5 个 tb 加入工程，`data/hex` 与 `data/vectors` 拷到 XSim
运行目录，Run All 后看 Console 的 ALL PASS。

---

## 3. 交付物清单

- **算法/验证**：`golden_model/`（定点位真参考）+ `tests/`（64 项自检）
- **RTL**：`rtl/`（层引擎、ROM/LUT、顶层、AXI 外壳、5 个 testbench）
- **数据**：`data/`（交付权重落位、ROM hex、27 组 golden 向量、仿真日志）
- **脚本**：`scripts/`（向量/hex/权重数组生成、误差统计、Q 格式实验、Vivado 批处理）
- **软件**：`sdk/`（PS 裸机程序 main.c、PC 客户端 udp_client.py、建工程文档）
- **文档**：`docs/`（总体介绍、定点规格书、以太网协议、实验报告、排障记录、测试手册）
- **流程**：`run_synth_impl.tcl`（非工程综合+实现）、`scripts/vivado/`（IP 封装/BD 建图）

---

## 4. 关键决策记录（早期问题均已有结论）

| 问题 | 结论 |
|---|---|
| 激活函数 | **ELU**（ReLU 版模型表现不佳，不重训；硬件 LUT+插值实现） |
| 定点位宽 | **权重 int16 + 激活 int18 + 输入 int16(Q6.10) + 累加器 40bit**；纯 int16 激活实测超预算，18bit 过线（docs/qformat_experiment.md） |
| Q 格式统一 or 逐层 | **逐层**（统一实测误差超预算 14~33 倍，实验报告见 docs/） |
| 环境 step 时延 | 不做要求（全局规划后调用，非实时环路）→ 16 lane @100MHz 足够 |
| 归一化位置 | **PS 端 double 浮点**（z=(x-mean)/√var，参数已交付） |
| 权重加载 | **PS 启动时经 AXI 写 URAM**（URAM 硅片不支持 bitstream 初始化；BRAM 放不下） |
| 舍入/溢出 | 四舍五入（规则①②，见 spec）/ 饱和 clamp |
| 适用范围 | 仅非奇异转移场景（模型同学确认） |

---

## 5. 目录结构

```
RL_project/
├── config/
│   └── model_config.py        # 全网参数总表（net_V 结构 + Q 格式定稿）
├── golden_model/              # golden model（定点位真参考）
│   ├── reader.py / quantize.py / layers.py / network.py
│   ├── elu_lut.py             # ELU LUT+插值（硬件方案同源）
│   └── bn_fold.py             # （真实模型无 BN，保留不用）
├── data/
│   ├── weights/ biases/       # 交付权重/bias txt（已落位）
│   ├── net_V_input_normalization.txt   # 输入归一化 mean/var
│   ├── hex/                   # ROM 初始化（gen_hex.py 生成）
│   │   ├── weights_all.hex    # 权重 256bit 打包字 ×82464（PS 启动时加载）
│   │   ├── bias_all.hex       # bias 40bit ×3073（随 bitstream）
│   │   └── elu_lut.hex        # ELU 5 张去重表 ×1157（随 bitstream）
│   ├── vectors/               # testbench golden 向量（27 案例）+ 仿真日志 + ref.txt
│   └── test_samples/sample_00/   # 交付测试样本（逐层输出）
├── scripts/
│   ├── fixed_point_stats.py   # 2 万样本部署误差统计验收
│   ├── qformat_experiment.py  # Q 格式统一化对比实验
│   ├── gen_hex.py / gen_golden_vectors.py / gen_weights_c.py / gen_pc_test_vectors.py
│   └── vivado/                # IP 封装、BD 建图、hex hook 等批处理 tcl
├── tests/                     # 4 个自检（量化/全链/ELU/bit-true，共 64 项）
├── rtl/
│   ├── signed_mac.v / simple_neuron.v (+tb)   # 练习模块
│   ├── net_v_top.v            # 顶层：start/done + 7 输入寄存器
│   ├── fc_engine.v            # 层引擎（16 lane 输入并行，7 层时分复用）
│   ├── weight_rom.v           # 权重存储（256bit 字，ram_style=ultra，84×URAM288）
│   ├── bias_rom.v / elu_lut.v # bias ROM / ELU LUT+插值
│   ├── axi/net_v_axi.v        # AXI-Lite 外壳（寄存器映射 + 权重加载口）
│   └── tb/                    # 5 个 testbench（端到端/分层/单层调试/AXI 外壳）
├── sdk/
│   ├── src/main.c             # PS 裸机程序（权重加载+归一化+推理+UDP 服务）
│   ├── src/weights.h          # 权重 C 数组（gen_weights_c.py 生成）
│   ├── pc_client/             # PC 端 Python 客户端（ping/sample/batch/run/--selftest）
│   └── README_build.md        # SDK 建工程文档（批处理+GUI 两版）
├── constraints/timing.xdc     # 100MHz 时钟约束
├── run_synth_impl.tcl         # 非工程模式综合+实现批处理
├── run_impl_project.tcl       # 工程模式（含 IP）综合+实现批处理
├── docs/                      # 全部文档（见下）
└── README.md
```

`docs/` 清单：`项目总体介绍.md`（总览入口）、`fixed_point_spec.md`（定点规格书）、
`ethernet_protocol.md`（UDP 协议对接）、`qformat_experiment.md`（量化实验报告）、
`testing_runbook.md`（测试实习手册）。

---

## 6. 项目已完成（2026-08-15）

所有阶段闭环：① golden model 浮点对齐交付数据；② 定点位真方案（18bit 激活，
p99.9=1.44m/s 过 1.5 自留线）；③ RTL + 三重仿真逐 bit 验证；④ 综合实现
（BD 集成 WNS=+1.277ns）；⑤ 上板串口自检逐 bit 一致 + lwIP UDP 27/27 联调通过。
**总览文档：`docs/项目总体介绍.md`**；排障与验收细节见 `docs/` 其余文档。

