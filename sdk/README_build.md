# net_V ZCU104 SDK 裸机工程 — 构建与上板指南

本目录是 SDK 软件侧源码与脚本。硬件侧产物见 `RL_project_bd/`（姊妹目录）。
协议与联测见 `RL_project/docs/ethernet_protocol.md`。

## 文件

| 文件 | 说明 |
|---|---|
| `src/main.c` | 裸机程序：权重加载 → 串口自检 → lwIP UDP 推理服务（192.168.1.10:5000） |
| `src/weights.h` | 82,464×256bit 权重表（约 8.9MB，由 RL_project `scripts/gen_weights_c.py` 生成，勿手改） |
| `src/weights_preview.txt` | 权重前/末 5 字的人眼预览 |
| `src/platform_zynqmp.c` / `platform.h` / `platform_config.h` | lwIP 平台骨架（沿用 Xilinx lwip_echo_server 模板：TTC0 周期定时 + GIC） |
| `create_sdk_ws.tcl` | xsct 首次建工作区 |
| `fix_lwip_bsp.tcl` | BSP 加 lwip202（**直接改 system.mss 文本**，见下注） |
| `fix_app_relink.tcl` | 重建 app 工程（让链接行带上 -llwip4）；也用于 main.c 更新后的重编 |
| `rebuild_all.tcl` | 补齐 fsbl/pmufw 的 BSP 编译（首轮漏建时用） |
| `boot.bif` | bootgen 输入（fsbl → pmufw → bit → app） |
| `pc_client/` | PC 端 Python 客户端 + 27 组测试向量（见协议文档） |
| `ws/` | xsct 生成的工作区（hw0/bsp0/net_v_app/fsbl/pmufw） |

## 批处理建工程（已验证，lwIP 终版）

```cmd
cd /d C:\yshlearn\FPGA_learn\RL_project_sdk
call C:\Xilinx\SDK\2018.3\bin\xsct.bat create_sdk_ws.tcl
call C:\Xilinx\SDK\2018.3\bin\xsct.bat rebuild_all.tcl
call C:\Xilinx\SDK\2018.3\bin\xsct.bat fix_lwip_bsp.tcl
call C:\Xilinx\SDK\2018.3\bin\xsct.bat fix_app_relink.tcl
call C:\Xilinx\SDK\2018.3\bin\bootgen.bat -arch zynqmp -image boot.bif -w on -o BOOT.bin
```

流程说明与 2018.3 实测坑：

1. `create_sdk_ws.tcl`：`createhw(hdf) → createbsp(bsp0, psu_cortexa53_0,
   standalone) → createapp(net_v_app, Empty Application)`，清空模板 src
   （保留 lscript.ld）后 `importsources src/` 并编译；fsbl/pmufw 同建。
2. `rebuild_all.tcl`：补 fsbl_bsp/pmufw_bsp 的首轮编译。
3. `fix_lwip_bsp.tcl`：给 bsp0 加 lwIP。**注意 xsct 的 `setlib` 对已存在
   工程静默不落盘**（mss 无 LIBRARY 段、getlibs 仍报 No libs）——脚本直接
   往 `ws/bsp0/system.mss` 末尾追加 BEGIN LIBRARY（lwip202 1.2，
   lwip_dhcp=false），再重编 BSP 生成 `libsrc/lwip202_v1_2` 与
   `lib/liblwip4.a`。
4. `fix_app_relink.tcl`：既有 app 工程的链接行在建工程时定型（无 -llwip4），
   只能删工程重建（源码真本在 src/，工程里是副本，删除安全）。
5. 本端口 lwIP 配置 `NO_SYS=1 + NO_SYS_NO_TIMERS=1`（Xilinx raw 惯例）：
   没有 `sys_check_timeouts`，ARP 不老化（直连无碍）；链路状态由 TTC0 周期
   跑 `eth_link_detect`。lwIP 2.0.2 用 `udp_new()`（无 udp_create）。
   EMAC 中断由端口层（xemacpsif）自注册，app 只需开 GIC+IRQ。

产物（均已实测生成）：`ws/net_v_app/Debug/net_v_app.elf`（3.66MB 含 lwIP）、
`ws/fsbl/Debug/fsbl.elf`、`ws/pmufw/Debug/pmufw.elf`、`BOOT.bin`（22.3MB）。

## GUI 手动步骤（退路）

1. 打开 SDK：`File → Launch SDK`，先指向 `RL_project_bd/bd_proj`（Vivado 里
   File → Export → Launch SDK），或直接 xsdk 新建 workspace 到 `RL_project_sdk/ws`。
2. `File → New → Hardware Platform Specification`，选
   `RL_project_bd/sdk/net_v_bd.hdf`，工程名 hw0。
3. `File → New → Board Support Package`：standalone，psu_cortexa53_0，名 bsp0。
   建好后打开 `system.mss` → Modify this BSP's Settings → 勾选 **lwip202**
   （dhcp 保持关），OK 让它重新生成。
4. `File → New → Application Project`：名 net_v_app，HW=hw0，BSP=bsp0，
   proc=psu_cortexa53_0，OS=standalone，模板 **Empty Application**。
5. 删掉模板 src 里的 main.c 等（保留 lscript.ld），把 `src/` 下的
   main.c、weights.h、platform.h、platform_config.h、platform_zynqmp.c
   拷进 `net_v_app/src/`。
6. 右键工程 → Build Project（链接行应自动带 -llwip4）。
7. 需要启动镜像的话同样方法建 fsbl（模板 Zynq MP FSBL）和 pmufw
   （模板 ZynqMP PMU Firmware，proc 选 psu_pmu_0），再用
   `Xilinx → Create Boot Image → Zynq MP`：顺序 fsbl.elf → pmufw.elf →
   design_1_wrapper.bit → net_v_app.elf，输出 BOOT.bin 拷 SD 卡。

## 启动顺序与串口

- SD 启动：BOOT.bin = FSBL →（FSBL 内）PMUFW → 配置 PL（bitstream）→
  跳转 net_v_app.elf。裸机链路全部由 FSBL 完成 PS 初始化。
- UART：ZCU104 USB-UART，**115200 8N1**（板级预设决定，无须软件配置）。
- 权重加载约 82.5 万次 AXI 写，预计几十毫秒级（程序里用 XTime 打印实测）。

## 预期打印输出样例

```
===== net_V ZCU104 裸机推理 + UDP 服务 =====
weights loaded: 82464 words x 256bit, <N> ms
soft_reset done=0（应为 0）
x0: q=739 期望 739 OK
x1: q=-1744 期望 -1744 OK
x2: q=167 期望 167 OK
x3: q=768 期望 768 OK
x4: q=-2194 期望 -2194 OK
x5: q=-222 期望 -222 OK
x6: q=922 期望 922 OK
acc7 = 0x000000001ea68081（期望 0x000000001ea68081） bit-true
ΔV = 490.406 m/s，期望 490.406，误差 0.000 m/s，推理 826 us
SELFTEST PASS（与 golden 逐 bit 一致）
UDP 服务就绪：192.168.1.10:5000（lwIP raw，无 DHCP）
```

## 板上验证清单（三方一致）

1. PL 侧仿真 golden：acc7 = `0x001ea66b88`，ΔV = 490.4013 m/s（iverilog 三重验证过）。
2. 板子上 `SELFTEST PASS` 且 acc7 与上面逐 bit 相等。
3. 若 ΔV 离谱（比如全 0/垃圾）：先怀疑权重没加载（URAM 上电空白）或
   加载时被中断——load_weights 必须在任何推理前完整跑完。
4. 若 done 超时：查 PL 是否已配置（bitstream 是否随 BOOT.bin 下去）、
   pl_clk0 是否 100MHz。

## 备注

- IP 基址 0xA000_0000 来自 BD 地址编辑器（HPM0 FPD 窗口）；standalone BSP
  的默认 MMU 表把该区域映射为 device memory，Xil_In32/Out32 无 cache 问题。
- 权重加载口与推理互斥由软件协议保证（加载完成前不发 start）。
- ΔV 打印用 0.001 m/s 整数是因为 xil_printf 不支持 %f。
