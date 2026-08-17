# net_V 以太网通信协议（ZCU104 ↔ 主机）

> 版本 v1.0（2026-08-15）。给仿真环境/主机侧同学对接用。
> 实现：板端 `sdk/src/main.c`（lwIP 2.0.2 raw API，standalone BSP）；
> 主机端参考实现 `sdk/pc_client/udp_client.py`。

## 1. 链路参数

| 项 | 值 |
|---|---|
| 板端 IP / 掩码 / 网关 | **192.168.1.10** / 255.255.255.0 / 192.168.1.1（固定，无 DHCP） |
| 板端 MAC | 00:0A:35:00:01:02（多板同链时改 `main.c` 里 `mac[]`） |
| UDP 端口 | **5000**（板=服务端，主机=客户端） |
| 物理层 | GEM3 → MIO RGMII → 板上 PHY，1 Gbps 自协商 |
| 字节序 | **全字段小端**（A53 与 x86 都是小端，结构体直接 memcpy） |

## 2. 消息格式

### 2.1 推理请求（PC→板），36 字节

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0 | magic | u32 | `0x4E565231`（"NVR1"） |
| 4 | seq | u32 | 序号，应答原样带回（主机用来对包/查丢） |
| 8 | x[0] | f32 | h0（km） |
| 12 | x[1] | f32 | I0（rad） |
| 16 | x[2] | f32 | hf−h0（km） |
| 20 | x[3] | f32 | If−I0（rad） |
| 24 | x[4] | f32 | ΔΩ = ωf−ω0（rad） |
| 28 | x[5] | f32 | fmax（m/s²） |
| 32 | x[6] | f32 | tf（s） |

- 输入是**原始物理量**（不归一化）；板端用 double 做归一化 + Q6.10 量化，
  量化与 golden model 逐 bit 一致。f32 传原始量的相对误差 ~1e-7，
  对最终结果影响 ≪ 判定容差（0.5 m/s）。
- 长度不是 36 字节的 NVR1 包直接丢弃（板端计数并串口告警）。

### 2.2 推理应答（板→PC），20 字节

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0 | magic | u32 | `0x4E565232`（"NVR2"） |
| 4 | seq | u32 | 与请求的 seq 一致 |
| 8 | dv | f32 | **ΔV，单位 m/s**（40bit 累加器 × 2^-20 反量化） |
| 12 | status | u32 | bit0=ok（1=推理完成；0=PL 超时，此时 dv=0） |
| 16 | infer_us | u32 | PL 推理耗时（µs），XTime 打点：发 start 到 done 拉高 |

### 2.3 链路自检（echo）

PC→板发 `magic = 0x4E434B00`（"NCK\0"）开头的**任意内容包**（≤255 字节，
建议 `magic | u32 seq | 短 payload`），板子**原样弹回全部字节**。
用于不通推理逻辑、纯验证链路/接线/防火墙。应答无固定格式——收到与原包
逐字节相同即通。

### 2.4 其他

magic 未识别的包：板端丢弃并计数（串口可观察）。协议保留演进位：新增消息
类型 = 新增 magic；现有两个消息长度固定，主机按 magic+长度解析即可向前兼容。

## 3. 时序与时延打点

- PL 单样本推理约 **0.83 ms**（82,464 发射拍 + 层切换 @100MHz），应答里的
  `infer_us` 是实测值。
- UDP 往返时延（主机侧测）= 链路 + 板端处理 + 推理。`udp_client.py batch`
  会打印 rtt 与 infer_us 的 min/max/avg。
- 板端串口每 64 个包打印一次摘要（infer #N / echo #N），bring-up 时观察用。

## 4. 主机客户端用法（参考实现）

```bash
cd RL_project/sdk/pc_client
python3 udp_client.py --selftest    # 本地自检（假 socket，不需要板子）
python3 udp_client.py ping          # 链路自检（4 个 echo 包）
python3 udp_client.py sample        # sample_00：期望 ΔV=490.44±0.5
python3 udp_client.py batch         # pc_test_vectors.json 全 27 组
python3 udp_client.py batch --board 192.168.1.10 --port 5000 --timeout 2.0
```

`pc_test_vectors.json` 由 `RL_project/scripts/gen_pc_test_vectors.py` 生成
（与 golden 向量同一采样链：sample_00 + seed=777 随机 10 组 + 16 组边界；
期望 ΔV 为浮点前向值，判定容差 0.5 m/s）。

## 5. 板上测试步骤（插线后）

1. PC 网卡设 192.168.1.100/24，网线直连 ZCU104，确认链路 Up 1Gbps。
2. SD 卡启动新 BOOT.bin（含 lwIP 版 app）。串口（115200 8N1）应看到：
   权重加载 → SELFTEST PASS → `UDP 服务就绪：192.168.1.10:5000`。
3. PC 上先 `python3 udp_client.py ping`（4/4 OK 再往下）。
4. `python3 udp_client.py sample` → PASS（ΔV≈490.4）。
5. `python3 udp_client.py batch` → 27/27 PASS，记录 infer_us / rtt 统计。
6. 常见问题：
   - ping 不通 → 查 PC 防火墙/网卡选线/板端串口是否打印就绪行；
   - ping 通但推理超时 → status=0，查 PL 是否配置、权重是否加载；
   - ΔV 全错 → 多半权重没加载完就收到包（正常流程不会发生，加载在
     网络初始化之前完成）。

## 6. 演进说明

- 将来接真正的仿真环境机器：只改主机端 IP/发包节奏，协议不变。
- 如需连续状态流（周期推理），可新增 magic 类型复用同一端口；板端
  主循环是单线程收包→推理→回包，天然串行，主机按 seq 对包即可。
