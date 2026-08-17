`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_layer_debug_tb.v — 单层独立验证 testbench（定位到问题层后单独复跑）
//
// 用途：全网 tb（net_v_top_tb / net_v_layers_tb）定位到"样本 s 第 k 层"出错
//       后，用本 tb 只跑这一层：把第 k-1 层的输出（= 第 k 层的输入，数据现成，
//       见 data/vectors/README.md）直接灌进 DUT 激活 buffer，poke 引擎从
//       第 k 层起跑，比对第 k 层输出，把排查范围缩到单层单样本。
//
// 用法（plusargs，缺省 SAMPLE=0 LAYER=1）：
//   iverilog -g2005 -s net_v_layer_debug_tb -o /tmp/dbg \
//       rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v \
//       rtl/net_v_top.v rtl/tb/net_v_layer_debug_tb.v
//   vvp /tmp/dbg +SAMPLE=0 +LAYER=3
// XSim 2018.3：xsim 命令行加 -testplusarg "SAMPLE=0" -testplusarg "LAYER=3"。
//
// 原理（依据 rtl/fc_engine.v 的实际逻辑）：
//   - 分层数据源：acts_sXX.hex 每样本 3072 行 = layer_01~06 输出各 512 行
//     连续存放；第 k 层输入 = 第 k-1 层输出 = 文件第 (k-2)*512..(k-1)*512-1 行。
//     （$readmemh 的起止地址参数选的是目标存储器地址、不是文件行号，
//     所以整文件读进 acts_mem[0:3071] 再按窗口取，与 net_v_layers_tb 一致。）
//   - poke 启动（不打 start 脉冲，否则 FSM 会从 layer 0 起跑）：复位松开、
//     DUT 停在 IDLE 后，在 negedge 用层次引用阻塞赋值灌 buffer + 改写 FSM
//     寄存器（state=S_RUN, layer_idx=k-1, ping=0, neuron_cnt=0, grp_cnt=0）。
//     IDLE 期间 cpipe 全 0（issue_v=0）、wb_cnt 被持续清零、acc40 无所谓
//     （每组 first 拍重载），所以从 S_RUN 直接起步是干净的。
//     ping=0 → src=A 区 act_buf[0:511]、dst=B 区 act_buf[512:1023]。
//   - 分三种情况：
//     k=1  ：inputs.hex 第 s 行 7 个 int16 → 符号扩展 18bit 灌 act_buf[0:6]，
//            act_buf[7:15] 清 0（与 fc_engine 正常 start 装载行为一致；
//            layer_01 只读 lane 0..15，其余无需灌）。
//     k=2..6：acts 第 k-1 层输出 512 行灌 act_buf[0:511]。
//     k=7  ：灌 layer_06 输出（acts 第 2560..3071 行），等 done 比 result
//            与 expected.hex 第 s 个值（40bit 全等）；末层线性不过 ELU。
//   - k=1..6：监视 layer_idx 从 k-1 跳到 k（= 第 k 层算完、B 区写完且
//     流水线已排空），等 3 拍读 act_buf[512+i] 与 acts 第 (k-1)*512..k*512-1
//     行逐 bit !== 比对；下一层只读 B 写 A，B 区在读数期间不会被改。
//
// 打印：单层 PASS/FAIL、前 20 处不符的神经元号+期望/实际、拍数；
//       超时 30 万拍保护；$finish 收尾。
//
// XSim 兼容：层次引用读/写存储器一律单变量下标（先 idx=base+i 再访问）；
//            存储器字先接到普通 reg 再位选（Verilog-2001 不允许存储器字
//            直接位选）。
//////////////////////////////////////////////////////////////////////////////

module net_v_layer_debug_tb;

    localparam N_SAMPLE = 27;
    localparam N_NEURON = 512;
    localparam TIMEOUT  = 300000;        // 最大等待拍数（单层实际 ≤1.7 万）

    reg               clk;
    reg               rst;
    reg               start;             // 本 tb 不打 start（poke 启动），恒 0
    reg  signed [15:0] x_in_0;           // 输入端口不驱动（数据走 buffer 灌）
    reg  signed [15:0] x_in_1;
    reg  signed [15:0] x_in_2;
    reg  signed [15:0] x_in_3;
    reg  signed [15:0] x_in_4;
    reg  signed [15:0] x_in_5;
    reg  signed [15:0] x_in_6;
    wire signed [39:0] result;
    wire              done;

    // golden 向量存储
    reg [15:0] in_mem   [0:N_SAMPLE*7-1];      // inputs.hex：每样本 7 字
    reg [17:0] acts_mem [0:6*N_NEURON-1];      // acts_sXX.hex：6 层 × 512
    reg [39:0] exp_mem  [0:N_SAMPLE-1];        // expected.hex：acc7

    integer s;                         // 样本号（+SAMPLE=，默认 0）
    integer k;                         // 层号 1..7（+LAYER=，默认 1）
    integer i;
    integer idx;
    integer cyc;
    integer seg_err;
    integer printed;
    reg [15:0] w16;                    // 输入字缓冲（先接出再符号扩展）
    reg [17:0] got;
    reg [8*64:1] fname;

    // 例化被测模块
    net_v_top dut (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .x_in_0 (x_in_0),
        .x_in_1 (x_in_1),
        .x_in_2 (x_in_2),
        .x_in_3 (x_in_3),
        .x_in_4 (x_in_4),
        .x_in_5 (x_in_5),
        .x_in_6 (x_in_6),
        .result (result),
        .done   (done)
    );

    // 100MHz 时钟（10ns 周期）
    initial clk = 0;
    always #5 clk = ~clk;

    // 主流程
    initial begin
        // ---- plusargs ----
        if (!$value$plusargs("SAMPLE=%d", s)) s = 0;
        if (!$value$plusargs("LAYER=%d",  k)) k = 1;
        if (s < 0 || s >= N_SAMPLE || k < 1 || k > 7) begin
            $display("用法: vvp <simv> +SAMPLE=<0..%0d> +LAYER=<1..7>（收到 SAMPLE=%0d LAYER=%0d）",
                     N_SAMPLE - 1, s, k);
            $finish;
        end
        $display("=== 单层独立验证: 样本 %0d, 层 %0d ===", s, k);

        // ---- golden 向量 ----
        $readmemh("data/vectors/inputs.hex", in_mem);
        $readmemh("data/vectors/expected.hex", exp_mem);
        if (s < 10)
            $sformat(fname, "data/vectors/acts_s0%0d.hex", s);
        else
            $sformat(fname, "data/vectors/acts_s%0d.hex", s);
        $readmemh(fname, acts_mem);

        // ---- 复位，DUT 停在 IDLE ----
        rst    = 1;
        start  = 0;
        x_in_0 = 0; x_in_1 = 0; x_in_2 = 0; x_in_3 = 0;
        x_in_4 = 0; x_in_5 = 0; x_in_6 = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;
        @(negedge clk);                 // IDLE 稳定：cpipe 全 0，wb_cnt 已清

        // ---- 灌第 k 层输入到 act_buf A 区（negedge 阻塞赋值，避开
        //      DUT 采样沿；单变量下标，XSim 兼容）----
        if (k == 1) begin
            for (i = 0; i < 7; i = i + 1) begin
                w16 = in_mem[s*7 + i];
                idx = i;
                dut.u_engine.act_buf[idx] = {{2{w16[15]}}, w16};
            end
            for (i = 7; i < 16; i = i + 1) begin
                idx = i;
                dut.u_engine.act_buf[idx] = 18'd0;
            end
        end else begin
            for (i = 0; i < N_NEURON; i = i + 1) begin
                idx = i;
                dut.u_engine.act_buf[idx] = acts_mem[(k-2)*N_NEURON + i];
            end
        end

        // ---- poke 启动：FSM 直接从第 k 层 S_RUN 起跑 ----
        dut.u_engine.layer_idx  = k - 1;
        dut.u_engine.ping       = 1'b0;   // src=A[0:511] dst=B[512:1023]
        dut.u_engine.neuron_cnt = 9'd0;
        dut.u_engine.grp_cnt    = 5'd0;
        dut.u_engine.state      = 2'd1;   // S_RUN

        // ---- 等第 k 层算完并比对 ----
        cyc = 0;
        if (k == 7) begin
            // 输出层：等 done，比 40bit 累加器原值
            while (done !== 1'b1 && cyc < TIMEOUT) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (done !== 1'b1) begin
                $display("FAIL: 样本 %0d 层 7 超时（%0d 拍未等到 done）", s, cyc);
            end else if (result !== exp_mem[s]) begin
                $display("FAIL: 样本 %0d 层 7 期望 acc7=%h 实际 %h",
                         s, exp_mem[s], result);
            end else begin
                $display("PASS: 样本 %0d 层 7  acc7=%h（40bit 全等，%0d 拍）",
                         s, result, cyc);
            end
        end else begin
            // 隐藏层：等 layer_idx 从 k-1 跳到 k（第 k 层写回完成）
            while (dut.u_engine.layer_idx == k - 1 && cyc < TIMEOUT) begin
                @(posedge clk);
                #1;
                cyc = cyc + 1;
            end
            if (cyc >= TIMEOUT) begin
                $display("FAIL: 样本 %0d 层 %0d 超时（%0d 拍未跳变）",
                         s, k, cyc);
            end else if (dut.u_engine.layer_idx != k) begin
                $display("FAIL: 样本 %0d 层 %0d 跳变异常（layer_idx=%0d）",
                         s, k, dut.u_engine.layer_idx);
            end else begin
                repeat (3) begin          // 数据已落稳，再等 3 拍保险
                    @(posedge clk);
                    #1;
                end
                seg_err = 0;
                printed = 0;
                for (i = 0; i < N_NEURON; i = i + 1) begin
                    idx = N_NEURON + i;   // 刚写完的 B 区
                    got = dut.u_engine.act_buf[idx];
                    if (got !== acts_mem[(k-1)*N_NEURON + i]) begin
                        if (printed < 20) begin
                            $display("FAIL: 样本 %0d 层 %0d 神经元 %0d 期望 %h 实际 %h",
                                     s, k, i, acts_mem[(k-1)*N_NEURON + i],
                                     got);
                            printed = printed + 1;
                        end
                        seg_err = seg_err + 1;
                    end
                end
                if (seg_err == 0)
                    $display("PASS: 样本 %0d 层 %0d (512/512，%0d 拍)",
                             s, k, cyc);
                else begin
                    if (seg_err > 20)
                        $display("      …（该层后续 %0d 处不符省略打印）",
                                 seg_err - 20);
                    $display("FAIL: 样本 %0d 层 %0d 共 %0d/512 个神经元不符",
                             s, k, seg_err);
                end
            end
        end
        $finish;
    end

endmodule
