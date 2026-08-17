`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// simple_neuron.v — 简化神经元（4 输入，权重存寄存器）
//
// 功能：y = ReLU( x0*w0 + x1*w1 + x2*w2 + x3*w3 + bias )
//
// 修复记录（2026-08-07）：
//   - 端口 unpacked array (x[0:3]) 改成扁平向量 x_flat[31:0]，
//     用 [idx*DW +: DW] 做 bit-select 索引（Verilog-2001 兼容）
//   - ACC_W 移到 #() 参数列表
/*
这个模块做完一个输出神经元的完整计算：y = ReLU(x·w + bias)。
引脚              作用
x_flat[31:0]    4 个输入（打平成一个 32 位向量）
w_flat[31:0]    4 个权重（同样打平）
bias[7:0]       偏置
start           启动脉冲（拉高一拍）
y[7:0]          结果
done            完成脉冲（单拍）

状态机走一遍（8 拍完成）：
IDLE     等 start=1 → 清零 acc、idx=0，进 COMPUTE
COMPUTE  拍0: acc += x[0]*w[0]，idx=1
         拍1: acc += x[1]*w[1]，idx=2
         拍2: acc += x[2]*w[2]，idx=3
         拍3: acc += x[3]*w[3]，idx=4 → 进 ADD_BIAS
ADD_BIAS acc_bias = acc + bias
ACTIVATE 如果 acc_bias < 0        → y=0（ReLU归零）
         如果 acc_bias > 127      → y=127（饱和）
         否则                     → y=acc_bias
DONE_S   done=1 → 回 IDLE
*/

/*
后面做 fc_engine 时，不会直接实例化 simple_neuron 这个模块——它的 4 输入、寄存器权重都是写死的。但它的设计思想直接迁移：

simple_neuron 里的概念	        fc_engine 怎么用
COMPUTE 状态里 idx 计数输入	     改成 BRAM 地址自增读权重
acc + prod 累加	               独立例化 P=16 个 MAC 单元并行算
ACTIVATE 状态 ReLU+饱和	        每个 MAC 输出端点一个
DONE 状态 done=1	            16 路都算完时拉层完成信号
整个状态机	                    拆成两层 FSM（层控制器 + 顶层）

*/
//////////////////////////////////////////////////////////////////////////////


module simple_neuron #(
    parameter DATA_W = 8,
    parameter IN_DIM  = 4,
    parameter ACC_W   = 18      // 2*DATA_W + log2(IN_DIM) ≈ 2*8+2=18
)(
    input  wire                     clk,
    input  wire                     rst,
    // 4 个输入，打平成一个向量：{x[3], x[2], x[1], x[0]}
    input  wire [DATA_W*IN_DIM-1:0] x_flat,
    // 4 个权重，同样打平
    input  wire [DATA_W*IN_DIM-1:0] w_flat,
    input  wire signed [DATA_W-1:0] bias,
    input  wire                     start,
    output reg  signed [DATA_W-1:0] y,
    output reg                      done
);

    localparam IDLE     = 3'd0;
    localparam COMPUTE  = 3'd1;
    localparam ADD_BIAS = 3'd2;
    localparam ACTIVATE = 3'd3;
    localparam DONE_S   = 3'd4;
    reg [2:0] state;

    reg signed [ACC_W-1:0] acc;
    reg signed [ACC_W-1:0] acc_bias;
    reg [2:0] idx;

    // 从扁平向量中取出当前索引的输入和权重
    wire signed [DATA_W-1:0] xi;
    wire signed [DATA_W-1:0] wi;
    assign xi = x_flat[idx*DATA_W +: DATA_W];
    assign wi = w_flat[idx*DATA_W +: DATA_W];

    wire signed [2*DATA_W-1:0] prod;
    assign prod = xi * wi;

    always @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            acc      <= {ACC_W{1'b0}};
            acc_bias <= {ACC_W{1'b0}};
            y        <= {DATA_W{1'b0}};
            done     <= 1'b0;
            idx      <= 3'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        acc   <= {ACC_W{1'b0}};
                        idx   <= 3'd0;
                        state <= COMPUTE;
                    end
                end

                COMPUTE: begin
                    acc <= acc + prod;
                    if (idx == IN_DIM - 1)
                        state <= ADD_BIAS;
                    else
                        idx <= idx + 1;
                end

                ADD_BIAS: begin
                    acc_bias <= acc + bias;
                    state    <= ACTIVATE;
                end

                ACTIVATE: begin
                    if (acc_bias[ACC_W-1])
                        y <= {DATA_W{1'b0}};
                    else if (acc_bias > {1'b0, {(DATA_W-1){1'b1}}})
                        y <= {1'b0, {(DATA_W-1){1'b1}}};
                    else
                        y <= acc_bias[DATA_W-1:0];
                    state <= DONE_S;
                end

                DONE_S: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
