`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_top_tb.v — net_v_top 全网自检 testbench（零容差逐 bit 比对）
//
// 流程：$readmemh 载入 data/vectors/ 下的 golden 向量（27 个样本：
//       sample_00 + 10 组 seed=777 随机包络样本 + 16 组边界案例），逐样本：
//         驱动 7 个 Q6.10 int16 输入 → 拉高一拍 start → 等 done →
//         比对 result 与期望 40bit 累加器（完全相等才算 PASS）→
//         顺便把 acc7 × 2^-20 的浮点 ΔV 打出来给人看
//       最后打印 PASS/FAIL 统计。
//
// 向量与 DUT 同源校验：期望由 golden model bit-true 路径生成
// （scripts/gen_golden_vectors.py），ROM hex 由 scripts/gen_hex.py 生成。
//
// 运行（工作目录必须是 RL_project，hex 相对路径才找得到）：
//   iverilog -g2005 -o simv rtl/weight_rom.v rtl/bias_rom.v rtl/elu_lut.v \
//            rtl/fc_engine.v rtl/net_v_top.v rtl/tb/net_v_top_tb.v \
//            -s net_v_top_tb
//   vvp simv
// Vivado 2018.3 XSim：把 6 个 .v 加入工程，3 个 ROM hex 和 2 个向量 hex
// 加入 simulation sources（或把上面参数改成绝对路径），跑 net_v_top_tb。
//
// 仿真量：单样本约 8.26 万拍，27 个样本约 223 万拍，每样本超时上限
// 30 万拍（防死等）。
//////////////////////////////////////////////////////////////////////////////

module net_v_top_tb;

    localparam N_SAMPLE = 27;
    localparam TIMEOUT  = 300000;        // 每样本最大等待拍数

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
    wire signed [39:0] result;
    wire              done;

    // golden 向量存储
    reg [15:0] in_mem  [0:N_SAMPLE*7-1];   // 每样本 7 个输入（Q6.10 补码）
    reg [39:0] exp_mem [0:N_SAMPLE-1];     // 每样本期望 acc7（40bit 补码）

    integer errors;
    integer s;
    integer cyc;
    integer total_cyc;
    integer hi;                            // ΔV 换算用：acc7 高 8 位（有符号）
    reg [31:0] lo;                         // ΔV 换算用：acc7 低 32 位（无符号）
    real    dv;

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
        $readmemh("data/vectors/expected.hex", exp_mem);

        rst    = 1;
        start  = 0;
        x_in_0 = 0; x_in_1 = 0; x_in_2 = 0; x_in_3 = 0;
        x_in_4 = 0; x_in_5 = 0; x_in_6 = 0;
        errors = 0;
        total_cyc = 0;

        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        for (s = 0; s < N_SAMPLE; s = s + 1) begin
            // 驱动输入 + start 脉冲（在 negedge 变更，避开 DUT 采样沿竞争）
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

            // 等 done（上一拍的 done 已在 start 生效沿清掉）
            cyc = 0;
            while (done !== 1'b1 && cyc < TIMEOUT) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            total_cyc = total_cyc + cyc;

            if (done !== 1'b1) begin
                $display("FAIL: 样本 %0d 超时（%0d 拍未等到 done）", s, cyc);
                errors = errors + 1;
            end else if (result !== exp_mem[s]) begin
                $display("FAIL: 样本 %0d 期望 %h 实际 %h", s, exp_mem[s], result);
                errors = errors + 1;
            end else begin
                // 40bit 有符号 → 实数 ΔV = acc7 × 2^-20（仅打印，不参与判定）
                hi = $signed({{24{result[39]}}, result[39:32]});
                lo = result[31:0];
                dv = (hi * 4294967296.0 + lo) / 1048576.0;
                $display("PASS: 样本 %0d  acc7=%h  ΔV=%.4f m/s  (%0d 拍)",
                         s, result, dv, cyc);
            end

            // 让 done 窗口走完（DUT 回 IDLE），再进下一样本
            @(posedge clk);
        end

        $display("----------------------------------------------------------");
        $display("样本数 %0d，总拍数约 %0d", N_SAMPLE, total_cyc);
        if (errors == 0)
            $display("=================== ALL PASS ===================");
        else
            $display("=================== %0d FAILURES ===================", errors);
        $finish;
    end

endmodule
