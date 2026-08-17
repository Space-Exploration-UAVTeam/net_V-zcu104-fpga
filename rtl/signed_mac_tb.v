`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// signed_mac_tb.v — signed_mac 的自检 testbench
//
// 功能：送几组已知输入，检查累加结果，自动打印 PASS/FAIL。
//
// 关键点（交接文档"自检 testbench"要求）：
//   - 不用人看波形，程序自动比对，输出 PASS/FAIL
//   - 覆盖：正数、负数、零、最大/最小值、清零、累加多拍
//
// 在 Vivado 里跑：把 signed_mac.v 和 signed_mac_tb.v 加进工程，
// 在 XSim 里选 signed_mac_tb 运行，看 Console 输出。
// 送 5 组测试——正数累加、负数累加、混合乘加、最大值边界、清零验证。task check(expected) 比对 acc 和期望值，不等就打印 FAIL 并计数。
//////////////////////////////////////////////////////////////////////////////

module signed_mac_tb;

    reg  clk;
    reg  rst;
    reg  signed [7:0] a;
    reg  signed [7:0] w;
    reg  acc_en;
    reg  acc_clear;
    wire signed [19:0] acc;

    integer errors = 0;

    // 例化被测模块
    signed_mac #(.DATA_W(8)) dut (
        .clk       (clk),
        .rst       (rst),
        .a         (a),
        .w         (w),
        .acc_en    (acc_en),
        .acc_clear (acc_clear),
        .acc       (acc)
    );

    // 100MHz 时钟（10ns 周期）
    initial clk = 0;
    always #5 clk = ~clk;

    // 检查任务：比对 acc 与期望值
    task check;
        input [19:0] expected;
        begin
            if (acc !== expected) begin
                $display("FAIL: 期望 %0d 实际 %0d", expected, acc);
                errors = errors + 1;
            end else begin
                $display("PASS: %0d", acc);
            end
        end
    endtask

    // 主测试
    initial begin
        // 初始
        rst       = 1;
        a         = 0;
        w         = 0;
        acc_en    = 0;
        acc_clear = 0;
        #20;

        // 退出复位
        rst = 0;
        #10;
        $display("--- 测试1: 正数累加 3*4 + 2*5 = 12+10 = 22 ---");
        acc_clear = 1; #10; acc_clear = 0;   // 清零
        a = 3; w = 4;  acc_en = 1; #10;
        a = 2; w = 5;  acc_en = 1; #10;
        acc_en = 0;    #10;
        check(22);

        $display("--- 测试2: 负数  -3*4 + 2*(-5) = -12-10 = -22 ---");
        acc_clear = 1; #10; acc_clear = 0;
        a = -3; w = 4;  acc_en = 1; #10;
        a = 2;  w = -5; acc_en = 1; #10;
        acc_en = 0;     #10;
        check(-22);

        $display("--- 测试3: 混合  -2*(-3) + 0*7 + 5*(-4) = 6+0-20 = -14 ---");
        acc_clear = 1; #10; acc_clear = 0;
        a = -2; w = -3; acc_en = 1; #10;
        a = 0;  w = 7;  acc_en = 1; #10;
        a = 5;  w = -4; acc_en = 1; #10;
        acc_en = 0;     #10;
        check(-14);

        $display("--- 测试4: 最大/最小值 127*(-128) = -16256 ---");
        acc_clear = 1; #10; acc_clear = 0;
        a = 127; w = -128; acc_en = 1; #10;
        acc_en = 0;      #10;
        check(-16256);

        $display("--- 测试5: 清零后再算 ---");
        acc_clear = 1; #10; acc_clear = 0;
        a = 1; w = 1; acc_en = 1; #10;
        acc_en = 0;    #10;
        check(1);

        // 汇总
        if (errors == 0)
            $display("=================== ALL PASS ===================");
        else
            $display("=================== %0d FAILURES ===================", errors);
        $stop;
    end

endmodule
