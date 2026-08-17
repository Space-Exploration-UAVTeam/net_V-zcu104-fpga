`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// fc_engine.v — net_V 全网点证层引擎（7 层时分复用，16 路输入并行）
//
// 功能：一次 start 跑完全网 7 层推理：
//         layer_01   7→512  ELU
//         layer_02~06 512→512 ELU ×5
//         layer_07   512→1  线性（输出 40bit 累加器原值）
//       数值语义逐字照抄 docs/fixed_point_spec.md（与 golden model bit-true
//       路径逐 bit 一致）：40bit 累加器、+bias、规则②四舍五入右移 CUT_POS、
//       饱和 18bit、ELU LUT；末层不截位不过 ELU。
//
// 架构（一拍处理 16 个输入元素）：
//   - 16 个乘法器（行为级 *，综合映射 DSP48），乘积 int18×int16→34bit
//   - 4 级流水线加法树 16→8→4→2→1（每级寄一拍）
//   - 一个神经元 = ceil(in/16) 拍：512 输入 32 拍，7 输入 1 拍
//   - 逐层参数（out_dim/NG/CUT_POS/各 ROM 基址/ELU 参数/是否末层）查表
//     切换；层间激活存 ping-pong 寄存器数组（512×18bit×2）
//
// 流水线时刻表（发射拍 = c；共 11 级）：
//   c     发射：组合驱动权重地址、控制束 {valid,first,last,nidx} 进 cpipe[0]
//   c+1   取数：权重 ROM 输出有效；act_buf 异步读（地址用迟 1 拍的组号
//         grp_d1）；拍末寄 a_r/w_r（16 lane）
//   c+2   乘：  prod_r[k] <= a_r[k]*w_r[k]（34bit）
//   c+3~6 树：  s1(8路35b) s2(4路36b) s3(2路37b) s4(1路38b)，每级寄一拍
//   c+7   累加：first→acc40<=s4，否则 acc40<=acc40+s4；
//         同拍组合驱动 bias 地址（取 cpipe[6] 的神经元号）
//   c+8   +bias：最后一组才做 acc_b <= acc40 + bias_q（规则：bias 最后累加）
//   c+9   截位：隐藏层 y_sat <= 饱和(规则②右移 CUT_POS)；
//         末层 result <= acc_b（不截位不过 ELU，40bit 原值）
//   c+10  ELU：  elu_y <= elu_lut(y_sat)（组合 LUT 输出寄一拍）
//   c+11  写回： act_buf[目的 buffer + nidx] <= elu_y，wb_cnt++
//
// 控制束 cpipe[0..10] 随流水线逐拍后移，各级按上表取自己的一拍；
// 层参数（cut_pos 等）在整层在飞期间不变，直接从 layer_idx 组合查表。
//
// 输入补 0 约定（layer_01 只有 7 个有效输入，用满 16 lane 的第一组）：
//   权重打包时 lane 7..15 已补 0（gen_hex.py），本模块装载输入时再把
//   act_buf[7..15] 清 0——0×0=0，双保险，部分和不受垃圾数据影响。
//
// 层切换无冒险：一层全部写回完成（wb_cnt == out_dim）后才翻 ping-pong
// 进入下一层，流水线此时已排空，读写 buffer 不打架。
//
// 时序提醒：单样本约 8.26 万拍（82464 次发射 + 7 次层切换排空）。
//////////////////////////////////////////////////////////////////////////////

module fc_engine #(
    parameter W_HEX = "data/hex/weights_all.hex",
    parameter B_HEX = "data/hex/bias_all.hex",
    parameter E_HEX = "data/hex/elu_lut.hex"
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,     // 启动脉冲（拉高一拍，IDLE/DONE 时有效）
    // 7 维输入，已按 Q6.10 量化的 int16（PS 给的）
    input  wire signed [15:0] x_in_0,
    input  wire signed [15:0] x_in_1,
    input  wire signed [15:0] x_in_2,
    input  wire signed [15:0] x_in_3,
    input  wire signed [15:0] x_in_4,
    input  wire signed [15:0] x_in_5,
    input  wire signed [15:0] x_in_6,
    output reg  signed [39:0] result,    // layer_07 累加器原值（含 bias）
    output reg                done,      // 完成标志（保持到下一次 start）
    // 权重加载口（PS 启动阶段经 AXI 外壳驱动；推理时 w_wr_en 恒 0）
    input  wire               w_wr_en,
    input  wire [16:0]        w_wr_addr,
    input  wire [255:0]       w_wr_data
);

    // ------------------------------------------------------------------
    // 层 FSM 状态
    // ------------------------------------------------------------------
    localparam S_IDLE  = 2'd0;   // 等 start（done 在本状态保持）
    localparam S_RUN   = 2'd1;   // 逐拍发射权重/激活组
    localparam S_DRAIN = 2'd2;   // 发射完，等本层神经元全部写回

    reg [1:0] state;
    reg [2:0] layer_idx;         // 0..6 对应 layer_01..07
    reg       ping;              // 0: 读 A 写 B；1: 读 B 写 A
    reg [8:0] neuron_cnt;        // 当前发射到第几个神经元（0..511）
    reg [4:0] grp_cnt;           // 当前神经元内第几组（0..NG-1）
    reg [4:0] grp_d1;            // grp_cnt 迟 1 拍（对齐权重 ROM 1 拍延迟）
    reg [9:0] wb_cnt;            // 本层已写回神经元数（0..512）

    // ------------------------------------------------------------------
    // 逐层参数表（combinational 查表；数值与 scripts/gen_hex.py 打印一致，
    // 改 Q 格式/层结构时两边同步改）
    //   cut_pos = acc_frac - act_frac（fixed_point_spec.md §3）
    //   fbits/ibits/lut_base：ELU LUT 参数（§4；layer_04/06 同 f=5 共享表）
    // ------------------------------------------------------------------
    reg  [9:0]  out_dim;         // 本层输出神经元数
    reg  [4:0]  ng_m1;           // 每组字数 NG-1（NG = ceil(in/16)）
    reg  [2:0]  ng_shift;        // log2(NG)：0（NG=1）或 5（NG=32）
    reg  [4:0]  cut_pos;         // CUT_POS（末层不用）
    reg  [16:0] w_base;          // 权重 ROM 字基址
    reg  [11:0] b_base;          // bias ROM 基址
    reg  [3:0]  fbits;           // act_frac（ELU 用）
    reg  [3:0]  ibits;           // 插值位数 IB
    reg  [10:0] lut_base;        // ELU 表基址
    reg         is_last;         // 末层（线性输出）

    always @(*) begin
        case (layer_idx)
        //         out  ng_m1 sh  cut  w_base b_base  f  ib  lut  last
        3'd0: begin
            out_dim=10'd512; ng_m1=5'd0;  ng_shift=3'd0;
            cut_pos=5'd13; w_base=17'd0;     b_base=12'd0;
            fbits=4'd12; ibits=4'd7; lut_base=11'd0;    is_last=1'b0;
        end
        3'd1: begin
            out_dim=10'd512; ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd17; w_base=17'd512;   b_base=12'd512;
            fbits=4'd10; ibits=4'd5; lut_base=11'd257;  is_last=1'b0;
        end
        3'd2: begin
            out_dim=10'd512; ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd17; w_base=17'd16896; b_base=12'd1024;
            fbits=4'd7;  ibits=4'd2; lut_base=11'd514;  is_last=1'b0;
        end
        3'd3: begin
            out_dim=10'd512; ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd16; w_base=17'd33280; b_base=12'd1536;
            fbits=4'd5;  ibits=4'd0; lut_base=11'd771;  is_last=1'b0;
        end
        3'd4: begin
            out_dim=10'd512; ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd16; w_base=17'd49664; b_base=12'd2048;
            fbits=4'd4;  ibits=4'd0; lut_base=11'd1028; is_last=1'b0;
        end
        3'd5: begin
            out_dim=10'd512; ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd13; w_base=17'd66048; b_base=12'd2560;
            fbits=4'd5;  ibits=4'd0; lut_base=11'd771;  is_last=1'b0;
        end
        default: begin  // 3'd6 = layer_07（线性，不截位不过 ELU）
            out_dim=10'd1;   ng_m1=5'd31; ng_shift=3'd5;
            cut_pos=5'd0;  w_base=17'd82432; b_base=12'd3072;
            fbits=4'd0;  ibits=4'd0; lut_base=11'd0;    is_last=1'b1;
        end
        endcase
    end

    // ------------------------------------------------------------------
    // ping-pong 激活 buffer：512×18bit×2（寄存器数组）
    //   [0:511] = buffer A，[512:1023] = buffer B
    //   层 l 从 src 读、往 dst 写；层结束翻 ping。
    //   注：只存纯位图，读出时靠目的寄存器（a_r 等 signed 声明）解释符号。
    // ------------------------------------------------------------------
    reg [17:0] act_buf [0:1023];
    wire [9:0] src_base = ping ? 10'd512 : 10'd0;
    wire [9:0] dst_base = ping ? 10'd0   : 10'd512;

    // ------------------------------------------------------------------
    // 发射控制束：{valid, first, last, nidx[8:0]}，随流水线逐拍后移
    //   cpipe[n] 在发射后第 n+1 拍有效 → ACC 取 [6]，BIAS 取 [7]，
    //   SHIFT 取 [8]，ELU 取 [9]，WB 取 [10]
    //   （注：Verilog-2001 不允许对存储器字做位选，所以先接出整条线）
    // ------------------------------------------------------------------
    wire        issue_v = (state == S_RUN);
    wire        issue_f = (grp_cnt == 5'd0);            // 本神经元第一组
    wire        issue_l = (grp_cnt == ng_m1);           // 本神经元最后一组
    wire [11:0] issue_bundle = {issue_v, issue_f, issue_l, neuron_cnt};

    reg [11:0] cpipe [0:10];
    wire [11:0] cpipe6  = cpipe[6];
    wire [11:0] cpipe7  = cpipe[7];
    wire [11:0] cpipe8  = cpipe[8];
    wire [11:0] cpipe9  = cpipe[9];
    wire [11:0] cpipe10 = cpipe[10];

    // ------------------------------------------------------------------
    // 权重 / bias ROM（同步读，1 拍延迟）
    // ------------------------------------------------------------------
    wire [16:0] w_addr = w_base + ({8'b0, neuron_cnt} << ng_shift)
                         + {12'b0, grp_cnt};
    wire [255:0] w_word;
    weight_rom #(.HEX_FILE(W_HEX)) u_wrom (
        .clk(clk), .addr(w_addr), .q(w_word),
        .wr_en(w_wr_en), .wr_addr(w_wr_addr), .wr_data(w_wr_data)
    );

    // bias 地址在 ACC 拍（c+7）组合给出，取 cpipe[6] 的神经元号
    wire [11:0] bias_addr = b_base + {3'b0, cpipe6[8:0]};
    wire signed [39:0] bias_q;
    bias_rom #(.HEX_FILE(B_HEX)) u_brom (
        .clk(clk), .addr(bias_addr), .q(bias_q)
    );

    // ------------------------------------------------------------------
    // 数据通路流水线寄存器
    // ------------------------------------------------------------------
    reg signed [17:0] a_r    [0:15];   // 取数级：16 lane 激活（int18）
    reg signed [15:0] w_r    [0:15];   // 取数级：16 lane 权重（int16）
    (* use_dsp = "yes" *)
    reg signed [33:0] prod_r [0:15];   // 乘级：34bit 乘积
    reg signed [34:0] s1_r   [0:7];    // 加法树第 1 级（16→8）
    reg signed [35:0] s2_r   [0:3];    // 加法树第 2 级（8→4）
    reg signed [36:0] s3_r   [0:1];    // 加法树第 3 级（4→2）
    reg signed [37:0] s4_r;            // 加法树第 4 级（2→1，16 路部分和）

    // 激活异步读地址（拍 c+1 用，grp_d1 对齐 ROM 延迟）
    wire [9:0] act_rd_base = src_base + {grp_d1, 4'b0000};
    wire [9:0] wb_addr     = dst_base + {1'b0, cpipe10[8:0]};

    // 16 lane 激活读数拍平成一条 288bit 线（XSim 2018.3 不接受 always 循环里
    // mem[wire+integer] 的索引写法 VRFC 10-536，改用 generate 持续赋值铺平）
    wire [287:0] act_word;
    genvar ga;
    generate
        for (ga = 0; ga < 16; ga = ga + 1) begin : G_ACT_RD
            assign act_word[ga*18 +: 18] = act_buf[act_rd_base + ga];
        end
    endgenerate

    // ------------------------------------------------------------------
    // 后处理寄存器
    // ------------------------------------------------------------------
    reg signed [39:0] acc40;           // 40bit 组间累加器（中途不饱和）
    reg signed [39:0] acc_b;           // +bias 后的完整累加结果
    reg signed [17:0] y_sat;           // 再量化 + 饱和后的 int18
    reg signed [17:0] elu_y;           // ELU LUT 输出（寄一拍）

    // 规则②：先加半 LSB 再算术右移；随后饱和到 18bit（组合逻辑）
    wire signed [39:0] half_w    = (40'sd1 <<< (cut_pos - 5'd1));
    wire signed [39:0] shifted_w = (acc_b + half_w) >>> cut_pos;
    reg  signed [17:0] sat_shift;
    always @(*) begin
        if (shifted_w > 40'sd131071)        // 2^17-1
            sat_shift = 18'sd131071;
        else if (shifted_w < -40'sd131072)  // -2^17
            sat_shift = -18'sd131072;
        else
            sat_shift = shifted_w[17:0];
    end

    // ELU LUT（纯组合，输出在 ELU 级寄一拍）
    wire signed [17:0] elu_y_w;
    elu_lut #(.HEX_FILE(E_HEX)) u_elu (
        .z(y_sat), .rom_base(lut_base), .fbits(fbits), .ibits(ibits),
        .y(elu_y_w)
    );

    // ------------------------------------------------------------------
    // 块 F：层 FSM + 发射计数器
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            layer_idx  <= 3'd0;
            ping       <= 1'b0;
            neuron_cnt <= 9'd0;
            grp_cnt    <= 5'd0;
            done       <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    layer_idx  <= 3'd0;
                    ping       <= 1'b0;
                    neuron_cnt <= 9'd0;
                    grp_cnt    <= 5'd0;
                    done       <= 1'b0;
                    state      <= S_RUN;
                end
            end

            S_RUN: begin
                // 每拍发射一组；组内计满换神经元，神经元计满换层
                if (grp_cnt == ng_m1) begin
                    grp_cnt <= 5'd0;
                    if (neuron_cnt == out_dim - 10'd1) begin
                        neuron_cnt <= 9'd0;
                        state      <= S_DRAIN;
                    end else begin
                        neuron_cnt <= neuron_cnt + 9'd1;
                    end
                end else begin
                    grp_cnt <= grp_cnt + 5'd1;
                end
            end

            S_DRAIN: begin
                // 等本层神经元全部写回（流水线排空），再翻 ping-pong 进下一层
                if (wb_cnt == out_dim) begin
                    if (layer_idx == 3'd6) begin
                        done  <= 1'b1;          // 7 层全完
                        state <= S_IDLE;
                    end else begin
                        layer_idx  <= layer_idx + 3'd1;
                        ping       <= ~ping;
                        neuron_cnt <= 9'd0;
                        grp_cnt    <= 5'd0;
                        state      <= S_RUN;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 块 C：控制束移位（11 级）
    // ------------------------------------------------------------------
    integer ci;
    always @(posedge clk) begin
        if (rst) begin
            for (ci = 0; ci < 11; ci = ci + 1)
                cpipe[ci] <= 12'd0;
        end else begin
            cpipe[0] <= issue_bundle;
            for (ci = 1; ci < 11; ci = ci + 1)
                cpipe[ci] <= cpipe[ci-1];
        end
    end

    // ------------------------------------------------------------------
    // 块 D：数据通路主流水线（自由流动，无效拍的垃圾由 valid 在下游拦截）
    // ------------------------------------------------------------------
    integer dk;
    always @(posedge clk) begin
        grp_d1 <= grp_cnt;
        // 取数级（拍 c+1 末）：权重 ROM 输出 + act_buf 异步读 → 寄存
        for (dk = 0; dk < 16; dk = dk + 1) begin
            a_r[dk] <= act_word[dk*18 +: 18];
            w_r[dk] <= w_word[dk*16 +: 16];
        end
        // 乘级（拍 c+2 末）：18bit × 16bit → 34bit（操作数 signed 声明，
        // 按 LHS 上下文位宽扩展，逐 bit 正确）
        for (dk = 0; dk < 16; dk = dk + 1)
            prod_r[dk] <= a_r[dk] * w_r[dk];
        // 加法树 4 级（每级 LHS 比操作数宽 1bit，自动符号扩展）
        for (dk = 0; dk < 8; dk = dk + 1)
            s1_r[dk] <= prod_r[2*dk] + prod_r[2*dk+1];
        for (dk = 0; dk < 4; dk = dk + 1)
            s2_r[dk] <= s1_r[2*dk] + s1_r[2*dk+1];
        s3_r[0] <= s2_r[0] + s2_r[1];
        s3_r[1] <= s2_r[2] + s2_r[3];
        s4_r    <= s3_r[0] + s3_r[1];
    end

    // ------------------------------------------------------------------
    // 块 P：后处理（累加/+bias/截位/ELU/写回）+ 输入装载 + 写回计数
    // ------------------------------------------------------------------
    integer pk;
    always @(posedge clk) begin
        if (rst) begin
            acc40      <= 40'sd0;
            acc_b      <= 40'sd0;
            y_sat      <= 18'sd0;
            elu_y      <= 18'sd0;
            result     <= 40'sd0;
            wb_cnt     <= 10'd0;
        end else begin
            // ACC 级（拍 c+7）：每组都累加；first 重新装载
            if (cpipe6[11]) begin
                if (cpipe6[10])
                    acc40 <= {{2{s4_r[37]}}, s4_r};
                else
                    acc40 <= acc40 + {{2{s4_r[37]}}, s4_r};
            end

            // BIAS 级（拍 c+8）：一个神经元只在最后一组做这一次
            if (cpipe7[11] && cpipe7[9])
                acc_b <= acc40 + bias_q;

            // SHIFT 级（拍 c+9）
            if (cpipe8[11] && cpipe8[9]) begin
                if (is_last)
                    result <= acc_b;        // 末层：累加器原值直接输出
                else
                    y_sat <= sat_shift;     // 规则②右移 + 饱和 18bit
            end

            // ELU 级（拍 c+10）
            if (cpipe9[11] && cpipe9[9] && !is_last)
                elu_y <= elu_y_w;

            // WB 级（拍 c+11）/ 末层在 SHIFT 级计数
            if (cpipe10[11] && cpipe10[9] && !is_last) begin
                act_buf[wb_addr] <= elu_y;
                wb_cnt <= wb_cnt + 10'd1;
            end else if (cpipe8[11] && cpipe8[9] && is_last) begin
                wb_cnt <= wb_cnt + 10'd1;
            end else if (state == S_IDLE
                         || (state == S_DRAIN && wb_cnt == out_dim)) begin
                wb_cnt <= 10'd0;            // 层结束/空闲时清零
            end

            // 输入装载（S_IDLE 收到 start 的这一拍，与 FSM 进 S_RUN 同拍）：
            // 7 个 int16 符号扩展到 18bit 写入 buffer A 的 0..6；
            // 7..15 清 0（配合权重 lane 补 0，见文件头注释）
            if (state == S_IDLE && start) begin
                act_buf[10'd0] <= {{2{x_in_0[15]}}, x_in_0};
                act_buf[10'd1] <= {{2{x_in_1[15]}}, x_in_1};
                act_buf[10'd2] <= {{2{x_in_2[15]}}, x_in_2};
                act_buf[10'd3] <= {{2{x_in_3[15]}}, x_in_3};
                act_buf[10'd4] <= {{2{x_in_4[15]}}, x_in_4};
                act_buf[10'd5] <= {{2{x_in_5[15]}}, x_in_5};
                act_buf[10'd6] <= {{2{x_in_6[15]}}, x_in_6};
                for (pk = 7; pk < 16; pk = pk + 1)
                    act_buf[pk] <= 18'd0;
            end
        end
    end

endmodule
