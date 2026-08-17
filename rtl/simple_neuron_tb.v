`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// simple_neuron_tb.v — simple_neuron 的自检 testbench
//
// 覆盖：正数、负数、零、ReLU 归零、最大值饱和
// 修复（2026-08-07）：unpacked array → 扁平向量，匹配 simple_neuron 新接口
//////////////////////////////////////////////////////////////////////////////

module simple_neuron_tb;

    parameter DATA_W = 8;
    parameter IN_DIM  = 4;

    reg  clk, rst;
    reg  [DATA_W*IN_DIM-1:0] x_flat;
    reg  [DATA_W*IN_DIM-1:0] w_flat;
    reg  signed [DATA_W-1:0] bias;
    reg  start;
    wire signed [DATA_W-1:0] y;
    wire done;

    integer errors = 0;

    simple_neuron #(.DATA_W(DATA_W), .IN_DIM(IN_DIM), .ACC_W(18)) dut (
        .clk    (clk),
        .rst    (rst),
        .x_flat (x_flat),
        .w_flat (w_flat),
        .bias   (bias),
        .start  (start),
        .y      (y),
        .done   (done)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ----- 辅助函数：把 4 个 byte 拼成扁平向量 ---------------------------------
    function [31:0] pack4;
        input [7:0] x0, x1, x2, x3;
        begin
            pack4 = {x3, x2, x1, x0};   // 高位对应高索引
        end
    endfunction

    // ----- 启动一次计算 --------------------------------------------------------
    task launch;
        input [7:0] x0, x1, x2, x3;
        input [7:0] w0, w1, w2, w3;
        input [7:0] b;
        begin
            x_flat = pack4(x0, x1, x2, x3);
            w_flat = pack4(w0, w1, w2, w3);
            bias   = b;
            @(posedge clk);
            start  = 1;
            @(posedge clk);
            start  = 0;
        end
    endtask

    // ----- 检查任务 ------------------------------------------------------------
    task check;
        input [7:0] expected;
        begin
            if (y !== expected) begin
                $display("FAIL: 期望 %0d 实际 %0d", expected, y);
                errors = errors + 1;
            end else begin
                $display("PASS: %0d", y);
            end
        end
    endtask

    // ----- 主测试 --------------------------------------------------------------
    initial begin
        rst = 1; start = 0; x_flat = 0; w_flat = 0; bias = 0;
        #20;
        rst = 0;
        #10;

        $display("--- 测试1: 1*2 + 2*3 + 3*4 + 4*5 + 1 = 2+6+12+20+1 = 41 ---");
        launch(1,2,3,4, 2,3,4,5, 1);
        @(posedge done); #1; check(41);

        $display("--- 测试2: -1*2 + 2*-3 + 3*4 + 4*5 + 0 = 24 ---");
        launch(-1,2,3,4, 2,-3,4,5, 0);
        @(posedge done); #1; check(24);

        $display("--- 测试3: ReLU归零: -5*2+0 = -10 → 0 ---");
        launch(-5,0,0,0, 2,1,1,1, 0);
        @(posedge done); #1; check(0);

        $display("--- 测试4: 全零 + bias=3 ---");
        launch(0,0,0,0, 0,0,0,0, 3);
        @(posedge done); #1; check(3);

        $display("--- 测试5: 饱和: 100*2*4=800 → 截断到127 ---");
        launch(100,100,100,100, 2,2,2,2, 0);
        @(posedge done); #1; check(127);

        if (errors == 0)
            $display("=================== ALL PASS ===================");
        else
            $display("=================== %0d FAILURES ===================", errors);
        $stop;
    end

endmodule
