`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_axi_tb.v — net_v_axi（AXI4-Lite 外壳）自检 testbench（零容差）
//
// 测试项：
//   a) 权重加载路径抽测：经 AXI 走 W_ADDR/W_D0~D7/W_COMMIT 流程改写
//      权重字 0、1（第二个不写 W_ADDR，验证地址自动 +1）和末字 82463，
//      经层次引用 dut.u_core.u_engine.u_wrom.mem[addr] 读回逐 bit 比对；
//      然后把 $readmemh 预载的原值写回去再确认（不恢复会影响后续推理）。
//   b) 全链路推理：写 X0~X6 → CTRL.start → 轮询 STATUS.done →
//      读 RESULT_LO/HI 拼 40bit → 与 expected.hex 逐 bit 比对。
//      跑 sample_00 / 05 / 12 / 26 共 4 个样本。
//   c) 软复位：CTRL.bit1=1 后确认 STATUS.done 清 0，释放后再跑一遍
//      sample_00 仍 PASS。
//
// AXI 读写 task 照 zynet top_sim.v 风格：NBA 驱动、见到 ready 后再多等
// 一拍让从机完成接收；bready/rready 用 always 块自动跟随 bvalid/rvalid。
//
// 运行（工作目录必须是 RL_project，hex 相对路径才找得到）：
//   iverilog -g2005 -s net_v_axi_tb -o /tmp/axi_tb rtl/weight_rom.v \
//            rtl/bias_rom.v rtl/elu_lut.v rtl/fc_engine.v rtl/net_v_top.v \
//            rtl/axi/net_v_axi.v rtl/tb/net_v_axi_tb.v && vvp /tmp/axi_tb
//
// XSim（Vivado 2018.3）注意：
//   - 7 个 .v 加入工程，data/hex 下 3 个 ROM hex + data/vectors 下 2 个
//     向量 hex + weights_all.hex 加入 simulation sources（或改绝对路径）。
//   - 存储器层次引用用单变量下标（check_wmem 里 mem[addr]，addr 是
//     task 输入寄存器），XSim 才认；不要写成 mem[addr+0] 之类的表达式。
//   - 单样本约 8.26 万拍，4+1 次推理共约 45 万拍，另加轮询开销。
//////////////////////////////////////////////////////////////////////////////

module net_v_axi_tb;

    localparam POLL_TIMEOUT = 300000;   // done 轮询次数上限（防死等）

    reg         clk;
    reg         aresetn;
    reg  [6:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [6:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    // golden 向量 + 权重原值（权重抽测后恢复用）
    reg [15:0]  in_mem  [0:27*7-1];    // 每样本 7 个输入（Q6.10 补码）
    reg [39:0]  exp_mem [0:26];        // 每样本期望 acc7（40bit 补码）
    reg [255:0] w_hex   [0:82463];     // weights_all.hex 原值

    integer errors;
    integer k;

    reg [255:0] pat0;
    reg [255:0] pat1;
    reg [255:0] pat2;
    reg [31:0]  rd;

    // 例化被测外壳
    net_v_axi dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (3'b000),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (3'b000),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready)
    );

    // 100MHz 时钟（10ns 周期）
    initial clk = 0;
    always #5 clk = ~clk;

    // bready/rready 自动跟随（zynet top_sim.v 做法）
    always @(posedge clk) begin
        bready <= bvalid;
        rready <= rvalid;
    end

    //------------------------------------------------------------------
    // AXI-Lite 写 task（照 zynet writeAxi：NBA 驱动，见 wready 后多等
    // 一拍——那一拍才是从机真正接收的沿）
    //------------------------------------------------------------------
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            awvalid <= 1'b1;
            awaddr  <= addr[6:0];
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            wait (wready);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            @(posedge clk);
        end
    endtask

    // AXI-Lite 读 task
    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            arvalid <= 1'b1;
            araddr  <= addr[6:0];
            wait (arready);
            @(posedge clk);
            arvalid <= 1'b0;
            wait (rvalid);
            @(posedge clk);
            data = rdata;
            @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------
    // 写一个 256bit 权重字：W_D0~D7 + W_COMMIT
    // （地址用 W_ADDR 当前值；COMMIT 后外壳自动 +1）
    //------------------------------------------------------------------
    task axi_commit_word;
        input [255:0] word;
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1)
                axi_write(32'h30 + (j << 2), word[32*j +: 32]);
            axi_write(32'h50, 32'h0);
            // COMMIT 触发的 mem 写与 axi_write 返回在同一个 posedge
            // （mem 写在 NBA 区），多等一拍再让调用方读回，避开竞争
            @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------
    // 层次引用读回 weight_rom 并逐 bit 比对
    // （XSim 注意：存储器层次引用用单变量下标，故 mem[addr]）
    //------------------------------------------------------------------
    task check_wmem;
        input [16:0]  addr;
        input [255:0] exp;
        reg   [255:0] got;
        begin
            got = dut.u_core.u_engine.u_wrom.mem[addr];
            if (got !== exp) begin
                $display("FAIL: 权重字 %0d 期望 %h 实际 %h", addr, exp, got);
                errors = errors + 1;
            end else begin
                $display("PASS: 权重字 %0d 写入正确（%h）", addr, exp);
            end
        end
    endtask

    //------------------------------------------------------------------
    // 经 AXI 跑一个样本：写输入 → start → 轮询 done → 读结果比对
    //------------------------------------------------------------------
    task run_sample;
        input integer s;
        integer polls;
        integer hi;
        reg [31:0] stat;
        reg [31:0] rlo;
        reg [39:0] res;
        real dv;
        begin
            axi_write(32'h08, {16'd0, in_mem[s*7+0]});
            axi_write(32'h0C, {16'd0, in_mem[s*7+1]});
            axi_write(32'h10, {16'd0, in_mem[s*7+2]});
            axi_write(32'h14, {16'd0, in_mem[s*7+3]});
            axi_write(32'h18, {16'd0, in_mem[s*7+4]});
            axi_write(32'h1C, {16'd0, in_mem[s*7+5]});
            axi_write(32'h20, {16'd0, in_mem[s*7+6]});
            axi_write(32'h00, 32'h1);              // CTRL.start（自清零脉冲）

            polls = 0;
            stat  = 32'd0;
            while (stat[0] !== 1'b1 && polls < POLL_TIMEOUT) begin
                axi_read(32'h04, stat);
                polls = polls + 1;
            end

            if (stat[0] !== 1'b1) begin
                $display("FAIL: 样本 %0d 超时（%0d 次轮询未等到 done）", s, polls);
                errors = errors + 1;
            end else begin
                axi_read(32'h24, rlo);             // RESULT_LO
                axi_read(32'h28, stat);            // RESULT_HI
                res = {stat[7:0], rlo};
                if (res !== exp_mem[s]) begin
                    $display("FAIL: 样本 %0d 期望 %h 实际 %h", s, exp_mem[s], res);
                    errors = errors + 1;
                end else begin
                    // 40bit 有符号 → 实数 ΔV = acc7 × 2^-20（仅打印）
                    hi = $signed({{24{res[39]}}, res[39:32]});
                    dv = (hi * 4294967296.0 + res[31:0]) / 1048576.0;
                    $display("PASS: 样本 %0d  acc7=%h  ΔV=%.4f m/s  (%0d 次轮询)",
                             s, res, dv, polls);
                end
            end
        end
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    initial begin
        $readmemh("data/vectors/inputs.hex",   in_mem);
        $readmemh("data/vectors/expected.hex", exp_mem);
        $readmemh("data/hex/weights_all.hex",  w_hex);

        aresetn = 0;
        awvalid = 0;  awaddr = 0;
        wdata   = 0;  wstrb  = 4'hF;  wvalid = 0;
        bready  = 0;
        arvalid = 0;  araddr = 0;
        rready  = 0;
        errors  = 0;

        repeat (8) @(posedge clk);
        @(negedge clk) aresetn = 1;
        repeat (2) @(posedge clk);

        //---------------- a) 权重加载路径抽测 ----------------
        $display("--- a) 权重加载路径抽测（W_ADDR/W_D0~7/W_COMMIT + 地址自增）---");
        for (k = 0; k < 8; k = k + 1) begin
            pat0[32*k +: 32] = 32'hA5000000 + k;   // 字 0：D0~D7 各不相同
            pat1[32*k +: 32] = 32'h5A000000 + k;   // 字 1：验自动 +1
            pat2[32*k +: 32] = 32'h12345670 + k;   // 末字 82463
        end
        axi_write(32'h2C, 32'd0);              // W_ADDR = 0
        axi_commit_word(pat0);
        check_wmem(17'd0, pat0);
        axi_commit_word(pat1);                 // 不写 W_ADDR → 验自动 +1
        check_wmem(17'd1, pat1);
        axi_write(32'h2C, 32'd82463);          // W_ADDR = 末字
        axi_commit_word(pat2);
        check_wmem(17'd82463, pat2);
        // 恢复 $readmemh 预载原值（不然后续推理必错），再读回确认
        axi_write(32'h2C, 32'd0);
        axi_commit_word(w_hex[0]);
        axi_commit_word(w_hex[1]);             // 同样靠自动 +1
        axi_write(32'h2C, 32'd82463);
        axi_commit_word(w_hex[82463]);
        check_wmem(17'd0,     w_hex[0]);
        check_wmem(17'd1,     w_hex[1]);
        check_wmem(17'd82463, w_hex[82463]);

        //---------------- b) 全链路推理（经 AXI）----------------
        $display("--- b) 全链路推理（写输入 → start → 轮询 done → 读结果）---");
        run_sample(0);
        run_sample(5);
        run_sample(12);
        run_sample(26);

        //---------------- c) 软复位 ----------------
        $display("--- c) 软复位（CTRL.bit1）---");
        axi_write(32'h00, 32'h2);              // soft_reset = 1
        axi_read(32'h04, rd);
        if (rd[0] !== 1'b0) begin
            $display("FAIL: 软复位后 STATUS.done 应为 0，实际读回 %h", rd);
            errors = errors + 1;
        end else begin
            $display("PASS: 软复位后 STATUS.done 清 0");
        end
        axi_write(32'h00, 32'h0);              // 释放软复位
        $display("复位释放后重跑 sample_00：");
        run_sample(0);

        $display("----------------------------------------------------------");
        if (errors == 0)
            $display("=================== ALL PASS ===================");
        else
            $display("=================== %0d FAILURES ===================", errors);
        $finish;
    end

endmodule
