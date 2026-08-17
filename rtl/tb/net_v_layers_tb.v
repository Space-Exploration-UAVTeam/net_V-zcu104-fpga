`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_layers_tb.v — 分层 testbench：逐层激活零容差逐 bit 比对
//
// 与 net_v_top_tb（只比最终 acc7）互补：本 tb 用层次引用监视 DUT 内部，
// 把 6 个隐藏层的每层 512 个 int18 激活全部与 golden 期望比对，
// 出错时能直接定位到"哪层哪个神经元"，不用对着波形猜。
//
// 原理（依据 rtl/fc_engine.v 的实际逻辑）：
//   - 层引擎跑完 layer l（0-based）时 layer_idx 从 l 跳到 l+1、ping 翻转；
//     刚写完的输出半区 = 新 ping 值下的 src 侧（src_base = ping?512:0）。
//     跳变发生在 DRAIN 排空确认（wb_cnt==out_dim）之后，512 项已全部落稳。
//   - 层 l+1 执行期间只读 src 半区、写另一半区（ping-pong），所以观察到
//     跳变后再等 3 拍读取是安全的（读取本身零仿真时间）。
//
// 流程：27 个样本（同 net_v_top_tb），逐样本：
//   驱动输入 → start → 对 l=0..5 等 layer_idx 跳变 → 读 512 项与
//   acts_sXX.hex 第 l 段逐 bit 比对（!==）→ 等 done 进下一样本。
//   每段比对打印一行 PASS/FAIL；末尾按层统计 + 总计；$finish 收尾。
//
// 期望数据：data/vectors/acts_s00~s26.hex（每文件 3072 行 = 6 层 × 512，
// gen_golden_vectors.py 生成，与 RTL 同源自检过）。
//
// 运行（工作目录 = RL_project；注意本环境的 iverilog 要求 -s 放源文件前）：
//   iverilog -g2005 -s net_v_layers_tb -o /tmp/netv_layers \
//       rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v \
//       rtl/net_v_top.v rtl/tb/net_v_layers_tb.v
//   vvp /tmp/netv_layers
//////////////////////////////////////////////////////////////////////////////

module net_v_layers_tb;

    localparam N_SAMPLE      = 27;
    localparam N_LAYER       = 6;      // 比对的隐藏层数（layer_01~06）
    localparam N_NEURON      = 512;
    localparam LAYER_TIMEOUT = 200000; // 单层最大等待拍数（实际 ≤1.7 万）
    localparam DONE_TIMEOUT  = 300000; // 每样本等 done 上限（实际 ~8.3 万）

    reg               clk;
    reg               rst;
    reg               start;
    reg  signed [15:0] x_in_0;
    reg  signed [15:0] x_in_1;
    reg  signed [15:0] x_in_2;
    reg  signed [15:0] x_in_3;
    reg  signed [15:0] x_in_4;
    reg  signed [15:0] x_in_5;
    reg  signed [15:0] x_in_6;
    wire signed [39:0] result;         // 本 tb 不比 acc7（net_v_top_tb 负责）
    wire              done;

    // golden 向量存储
    reg [15:0] in_mem   [0:N_SAMPLE*7-1];        // 每样本 7 个输入
    reg [17:0] acts_mem [0:N_LAYER*N_NEURON-1];  // 当前样本 6 层 × 512 期望

    integer layer_err [0:N_LAYER-1];   // 按层累计不符数
    integer total_err;
    integer s;
    integer l;
    integer i;
    integer cyc;
    integer base;
    integer seg_err;
    integer printed;
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
        .done   (done),
        .w_wr_en   (1'b0),
        .w_wr_addr (17'd0),
        .w_wr_data (256'd0)
    );

    // 100MHz 时钟（10ns 周期）
    initial clk = 0;
    always #5 clk = ~clk;

    // 主测试流程
    initial begin
        $readmemh("data/vectors/inputs.hex", in_mem);

        rst    = 1;
        start  = 0;
        x_in_0 = 0; x_in_1 = 0; x_in_2 = 0; x_in_3 = 0;
        x_in_4 = 0; x_in_5 = 0; x_in_6 = 0;
        total_err = 0;
        for (l = 0; l < N_LAYER; l = l + 1)
            layer_err[l] = 0;

        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        for (s = 0; s < N_SAMPLE; s = s + 1) begin
            // 载入本样本的逐层激活期望（文件名 acts_s00~s26，%02d 非
            // Verilog-2001 标准格式，用条件拼接保险）
            if (s < 10)
                $sformat(fname, "data/vectors/acts_s0%0d.hex", s);
            else
                $sformat(fname, "data/vectors/acts_s%0d.hex", s);
            $readmemh(fname, acts_mem);

            // 驱动输入 + start 脉冲（negedge 变更，避开 DUT 采样沿竞争）
            @(negedge clk);
            x_in_0 = in_mem[s*7+0];
            x_in_1 = in_mem[s*7+1];
            x_in_2 = in_mem[s*7+2];
            x_in_3 = in_mem[s*7+3];
            x_in_4 = in_mem[s*7+4];
            x_in_5 = in_mem[s*7+5];
            x_in_6 = in_mem[s*7+6];
            start  = 1;
            @(negedge clk);
            start  = 0;

            // 逐层监视：layer_idx 从 l 跳到 l+1 ⇒ 第 l 层输出已写完
            for (l = 0; l < N_LAYER; l = l + 1) begin
                cyc = 0;
                while (dut.u_engine.layer_idx == l && cyc < LAYER_TIMEOUT) begin
                    @(posedge clk);
                    #1;
                    cyc = cyc + 1;
                end

                if (cyc >= LAYER_TIMEOUT) begin
                    $display("FAIL: 样本 %0d 层 %0d 超时（%0d 拍未跳变）",
                             s, l + 1, cyc);
                    layer_err[l] = layer_err[l] + 1;
                    total_err    = total_err + 1;
                end else if (dut.u_engine.layer_idx != l + 1) begin
                    $display("FAIL: 样本 %0d 层 %0d 跳变异常（layer_idx=%0d）",
                             s, l + 1, dut.u_engine.layer_idx);
                    layer_err[l] = layer_err[l] + 1;
                    total_err    = total_err + 1;
                end else begin
                    // 稳定 3 拍再读（跳变沿数据已落稳，详见文件头注释）
                    repeat (3) begin
                        @(posedge clk);
                        #1;
                    end
                    // 刚写完的半区 = 新 ping 的 src 侧
                    base = (dut.u_engine.ping === 1'b1) ? 512 : 0;
                    seg_err = 0;
                    printed = 0;
                    for (i = 0; i < N_NEURON; i = i + 1) begin
                        got = dut.u_engine.act_buf[base + i];
                        if (got !== acts_mem[l*N_NEURON + i]) begin
                            if (printed < 20) begin
                                $display("FAIL: 样本 %0d 层 %0d 神经元 %0d 期望 %h 实际 %h",
                                         s, l + 1, i,
                                         acts_mem[l*N_NEURON + i], got);
                                printed = printed + 1;
                            end
                            seg_err = seg_err + 1;
                        end
                    end
                    if (seg_err == 0) begin
                        $display("PASS: 样本 %0d 层 %0d (512/512)", s, l + 1);
                    end else begin
                        if (seg_err > 20)
                            $display("      …（该层后续 %0d 处不符省略打印）",
                                     seg_err - 20);
                        $display("FAIL: 样本 %0d 层 %0d 共 %0d/512 个神经元不符",
                                 s, l + 1, seg_err);
                        layer_err[l] = layer_err[l] + seg_err;
                        total_err    = total_err + seg_err;
                    end
                end
            end

            // 等本样本 done（末层 acc7 由 net_v_top_tb 负责比对）
            cyc = 0;
            while (done !== 1'b1 && cyc < DONE_TIMEOUT) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (done !== 1'b1) begin
                $display("FAIL: 样本 %0d 超时（%0d 拍未等到 done）", s, cyc);
                total_err = total_err + 1;
            end

            // 让 done 窗口走完（DUT 回 IDLE），再进下一样本
            @(posedge clk);
        end

        $display("----------------------------------------------------------");
        for (l = 0; l < N_LAYER; l = l + 1)
            $display("层 %0d 不符数: %0d", l + 1, layer_err[l]);
        $display("总计: %0d 样本 × %0d 层 × %0d 神经元，不符 %0d 处",
                 N_SAMPLE, N_LAYER, N_NEURON, total_err);
        if (total_err == 0)
            $display("=================== ALL PASS ===================");
        else
            $display("=================== %0d FAILURES ===================", total_err);
        $finish;
    end

endmodule
