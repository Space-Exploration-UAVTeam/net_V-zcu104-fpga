# 测试实习手册（向量生成 → 各级仿真）—— 手把手版

> 先建立一个关键概念：**"跑 Verilog 仿真"= 用电脑上的仿真软件执行这些代码，
> 全程不碰 FPGA 板子**。仿真软件有两个：
>
> - **iverilog**（Mac 上已装好）：命令行工具，两条命令出结果，迭代最快；
> - **XSim**（Windows 上 Vivado 自带）：图形界面，是你今后的交付环境。
>
> 两者的代码和向量是同一套，结果必然一致。建议先在 Mac 上用 iverilog 把流程跑顺，
> 再到 Windows XSim 里复现。

---

## 第一部分：生成测试向量（Mac）

测试向量 = "标准答案"，由 golden model（Python）算出。这一步只需要 Python。

1. 打开 Mac 的"终端"（Terminal），输入：
   ```bash
   cd /Users/ysh/codex_use/FPGA_learn/RL_project
   python3 scripts/gen_golden_vectors.py
   ```
2. 它会做三件事：造 27 组输入（1 交付样本 + 10 随机 + 16 边界）→ 用 golden model
   的定点路径算出正确答案 → 写进 `data/vectors/` 目录。
3. 跑完去 `data/vectors/` 里能看到：
   - `inputs.hex` —— 27 行，每行 7 个 hex 数（27 个案例的 7 维输入）
   - `expected.hex` —— 27 行（每个案例的最终 40bit 期望输出）
   - `acts_s00.hex` ~ `acts_s26.hex` —— 每个案例 6 层 × 512 个神经元输出期望
   - `ref.txt` —— 人看的版本（原始输入、ΔV 等）

**想加自己的案例**：用编辑器打开 `scripts/gen_golden_vectors.py`，找到构造样本的段落
（有注释），照样子加一组（raw 输入 7 个数在包络内），重跑上面的命令即可。

---

## 第二部分：跑仿真（两种环境，选一个）

### 方案 A：Mac + iverilog（推荐先学这个）

打开终端，`cd /Users/ysh/codex_use/FPGA_learn/RL_project`，然后照抄。

#### A1. 端到端测试（"全网算得对不对"——只比最终结果）

```bash
iverilog -g2005 -s net_v_top_tb -o /tmp/netv_tb rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_top_tb.v
vvp /tmp/netv_tb
```

- 第一行 = 编译（把 5 个 RTL 模块 + 1 个 testbench 编成可执行的仿真程序 /tmp/netv_tb）
- 第二行 = 运行。约 1~2 分钟（27 个案例 × 8.2 万拍）
- 预期输出：27 行 `PASS: 样本 0  acc7=001ea66b88  ΔV=490.4013 m/s  (82547 拍)` 这样的，
  最后两行是 `样本数 27，总拍数约 2228769` 和 `=================== ALL PASS ===================`

#### A2. 逐层测试（"每一层分别对不对"——出错了能定位到哪层）

```bash
iverilog -g2005 -s net_v_layers_tb -o /tmp/netv_ltb rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_layers_tb.v
vvp /tmp/netv_ltb
```

- 预期输出：每个样本每层一行 `PASS: 样本 0 层 1 (512/512)`，共 162 行，
  最后 `总计: 27 样本 × 6 层 × 512 神经元，不符 0 处` + `ALL PASS`

#### A3. 单层独立复跑（"只练第 k 层"）

```bash
iverilog -g2005 -s net_v_layer_debug_tb -o /tmp/dbg rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_layer_debug_tb.v
vvp /tmp/dbg +SAMPLE=0 +LAYER=4
```

- `+SAMPLE=0 +LAYER=4` 的意思：把第 0 号案例第 3 层的输出灌进去，只跑第 4 层，
  然后比第 4 层的 512 个输出。预期：`PASS: 样本 0 层 4 (512/512，16396 拍)`
- 你可以改成任意组合：SAMPLE=0..26，LAYER=1..7（7 是输出层）

#### A4. AXI 外壳测试（"PS 接口对不对"）

```bash
iverilog -g2005 -s net_v_axi_tb -o /tmp/axi_tb rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v rtl/net_v_top.v rtl/axi/net_v_axi.v rtl/tb/net_v_axi_tb.v
vvp /tmp/axi_tb
```

- 预期：权重口抽测 PASS、4 个样本 acc7 逐 bit 相等、软复位重跑 PASS、末尾 `ALL PASS`

### 方案 B：Windows + Vivado XSim（图形界面）

仿真工程已经建好：`C:\yshlearn\FPGA_learn\study\RL_project\RL_project.xpr`。

#### B0. 一次性准备

1. 打开 Vivado 2018.3 → **Open Project** → 选上面的 .xpr
2. 检查文件是否齐全（左侧 Sources 窗口）：
   - Design Sources 下应有：`net_v_top`、`fc_engine`、`weight_rom`、`bias_rom`、`elu_lut`、
     `net_v_axi`（在 rtl/axi/）
   - Simulation Sources → sim_1 下应有 5 个 tb：`net_v_top_tb`、`net_v_layers_tb`、
     `net_v_layer_debug_tb`、`net_v_axi_tb`（外加早期的 signed_mac_tb/simple_neuron_tb）
3. **缺哪个加哪个**：File → Add Sources → Add or create simulation sources →
   Add Files → 到 `C:\yshlearn\FPGA_learn\RL_project\rtl\`（或 rtl\tb\、rtl\axi\）选文件
   （RTL 选 "Add or create design sources"，tb 选 simulation sources）
4. **确认 hex 数据在位**：打开文件夹
   `C:\yshlearn\FPGA_learn\study\RL_project\RL_project.sim\sim_1\behav\xsim\`，
   里面要有一个 `data` 文件夹（含 hex\ 和 vectors\）。没有就从
   `C:\yshlearn\FPGA_learn\RL_project\data` 整个拷贝过来。

#### B1. 跑任意一个 tb（以端到端为例）

1. Sources 窗口 → Simulation Sources → sim_1 → 右键 `net_v_top_tb` → **Set as Top**
   （名字变粗体就是设上了）
2. 左侧 Flow Navigator → Simulation → **Run Simulation** → **Run Behavioral Simulation**
3. 等编译，会弹出波形窗口。**注意：此时仿真只跑了 1000ns 就停了（默认设置），
   必须再点工具栏的 Run All（▶带两条竖线的图标），或在下方 Tcl Console 输入
   `run all` 回车**
4. 等 1~3 分钟，**结果在 Tcl Console 里看**：滚动到后面，27 行 PASS + `ALL PASS`
5. 换下一个 tb：File → Close Simulation → 右键另一个 tb → Set as Top → 重复 2~4

#### B2. 单层调试 tb 的传参（只它有参数）

Run Simulation **之前**：
1. 右键 sim_1（或 Flow Navigator → Simulation → Simulation Settings）
2. 找到 Simulation 选项卡里的 `xsim.simulate.xsim.more_options`（更多选项输入框）
3. 填：`-testplusarg "SAMPLE=0" -testplusarg "LAYER=4"` → 保存
4. 然后按 B1 正常跑。改层就改这个数字。

#### B3. 常见现象

- Tcl Console 里出现 `$readmemh ... cannot open` → B0 第 4 步的 data 没拷对位置
- 仿真停在 1000ns 不动 → 没点 Run All（B1 第 3 步）
- 输出乱码/问号 → 无所谓，看 PASS/FAIL 关键字即可（中文在 XSim 里编码问题）

---

## 第三部分：真机网络验证（Windows + 板子）

板子供电自启（SD 卡启动），网线连好，串口看到 `UDP 服务就绪` 后，在 Windows 上：

```cmd
cd /d C:\yshlearn\FPGA_learn\RL_project_sdk\pc_client
C:\software\work\anaconda3\python.exe udp_client.py ping     :: 链路自检，应 4/4
C:\software\work\anaconda3\python.exe udp_client.py sample   :: 交付案例，应 PASS
C:\software\work\anaconda3\python.exe udp_client.py batch    :: 27 组，应 27/27
C:\software\work\anaconda3\python.exe udp_client.py run 600 1.2 100 0.02 -1.0 0.002 10000000
```

最后一条是自定义输入（h0 I0 Δh ΔI ΔΩ fmax tf 七个数，空格隔开）。
期望值在 Mac 上算：

```bash
cd /Users/ysh/codex_use/FPGA_learn/RL_project && python3 -c "
import numpy as np; from golden_model import network as n
x=np.array([600,1.2,100,0.02,-1.0,0.002,1e7]); c=n.load_network_cache_float()
print(n.forward_network_float(n.normalize_input(x), c))"
```

两者误差 <1.5 m/s 即正常（典型 <0.5）。

---

## 建议实习顺序

1. 方案 A 的 A1~A4 原样各跑一遍（全 PASS）——先建立"流程是通的"手感
2. 回第一部分加一组自己的案例 → 重生成向量 → 重跑 A1/A2，看新案例被验证
3. 用 A3 单独复跑某层，对照 `fixed_point_spec.md` 看那层的 Q 格式和 CUT_POS
4. 故意改坏一个期望值（比如 tb 里改一个数）重跑，看 FAIL 打印长什么样
5. 方案 B 在 XSim 里复现一遍 A1~A4（交付环境确认）
6. 第三部分真板验证你自己的输入
