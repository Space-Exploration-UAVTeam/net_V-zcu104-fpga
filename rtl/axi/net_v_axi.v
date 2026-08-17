`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// net_v_axi.v — net_v_top 的 AXI4-Lite 从机外壳（ZCU104 PS 寄存器接口）
//
// 功能：把 net_v_top 的 start/done/7 路输入/40bit 结果/权重加载口映射成
//       AXI4-Lite 寄存器。握手写法照抄 zynet axi_lite_wrapper.v
//       （aw_en 单 outstanding、无 WSTRB 部分写，Vivado 2018.3 模板风格），
//       只改了寄存器映射。时钟直接用 s_axi_aclk。

// 它是 AXI-Lite 从机外壳，把总线上的地址读写翻译成我们引擎的信号——写 0x080x300x50 → 组装成 256bit 打进权重 URAM 的加载口；
// 读 0x24/0x28 → 直接读引擎的 result 输出线；读 0x04 → 读 done 线。注意权重数据不进 FF，是进了 URAM（加载口）。

// 寄存器映射（32bit 字，偏移按字节）：
//   偏移        名称      读写  内容
//   0x00        CTRL      W    bit0=start（自清零脉冲，写完一拍后自动回 0）
//                              bit1=soft_reset（电平：写 1 复位核心、写 0 释放；
//                              与 s_axi_aresetn 取或后送核心 rst，参考 zynet
//                              顶层 softReset 做法）
//   0x04        STATUS    R    bit0=done（直接来自核心，保持到下一次 start）
//   0x08~0x20   X0~X6     W    7 个输入，低 16bit 有效（Q6.10 int16 补码）
//   0x24        RESULT_LO R    result[31:0]
//   0x28        RESULT_HI R    result[39:32] 符号扩展到 32bit（bit[31:8] 为符号）
//   0x2C        W_ADDR    W    权重字地址（17bit），每写一次 W_COMMIT 自动 +1
//   0x30~0x4C   W_D0~D7   W    8 个 32bit 组装一个 256bit 权重字（W_D0=最低 32bit）
//   0x50        W_COMMIT  W    写任意值 → 以 {W_D7..W_D0} 向 w_wr_addr=W_ADDR
//                              发一拍 w_wr_en 脉冲，随后 W_ADDR 自动 +1
//   读回约定：X/W_ADDR/W_D 返回当前寄存器值；CTRL 读回 {bit1=soft_reset,
//   bit0=0}；W_COMMIT 读回 0；未用偏移读回 0。
//
// 权重加载流程（PS 启动阶段，共 82,464 个 256bit 字）：
//   写 W_ADDR（仅首字需要）→ 写 W_D0~D7 → 写 W_COMMIT → 地址自动 +1 →
//   直接写下一字的 W_D0~D7 → W_COMMIT → …
// 互斥约定：推理期间 w_wr_en 恒 0（PS 协议保证加载完成后才发 start；外壳
//   不做仲裁，weight_rom 内部 read-first，加载与读流水互不干扰）。
//
// 复位：s_axi_aresetn 低有效，复位 AXI 握手与全部寄存器；
//   核心 rst = (~s_axi_aresetn) | soft_reset（CTRL.bit1）。
//
// 兼容：严格 Verilog-2001、Vivado 2018.3（端口宽度只用 #() 列表里的参数，
//   body 内 localparam 不参与端口声明；无 SystemVerilog 语法）。
//////////////////////////////////////////////////////////////////////////////

module net_v_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 7,   // 128 字节地址空间（0x00~0x50）
    parameter W_HEX = "data/hex/weights_all.hex",
    parameter B_HEX = "data/hex/bias_all.hex",
    parameter E_HEX = "data/hex/elu_lut.hex"
)(
    input  wire                          s_axi_aclk,
    input  wire                          s_axi_aresetn,   // 低有效
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready
);

    // AXI4LITE 内部信号（命名照 zynet 模板）
    reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                           axi_awready;
    reg                           axi_wready;
    reg  [1:0]                    axi_bresp;
    reg                           axi_bvalid;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg                           axi_arready;
    reg  [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg  [1:0]                    axi_rresp;
    reg                           axi_rvalid;

    // ADDR_LSB=2（32bit 字）；0x00~0x50 共 21 个字 → 5bit 字地址
    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 4;

    //------------------------------------------------
    //-- 用户寄存器（字地址 = axi_awaddr[6:2]）
    //------------------------------------------------
    reg        start_reg;           // CTRL.bit0：自清零 start 脉冲
    reg        soft_reset_reg;      // CTRL.bit1：软复位电平
    reg [15:0] x_reg0;
    reg [15:0] x_reg1;
    reg [15:0] x_reg2;
    reg [15:0] x_reg3;
    reg [15:0] x_reg4;
    reg [15:0] x_reg5;
    reg [15:0] x_reg6;
    reg [16:0] w_addr_reg;          // W_ADDR（W_COMMIT 后自动 +1）
    reg [31:0] wd_reg0;             // W_D0 = 256bit 字最低 32bit
    reg [31:0] wd_reg1;
    reg [31:0] wd_reg2;
    reg [31:0] wd_reg3;
    reg [31:0] wd_reg4;
    reg [31:0] wd_reg5;
    reg [31:0] wd_reg6;
    reg [31:0] wd_reg7;
    reg        w_wr_en_r;           // 向核心权重口发的一拍脉冲
    reg [16:0] w_wr_addr_r;
    reg [255:0] w_wr_data_r;

    wire signed [39:0] core_result;
    wire               core_done;
    wire               core_rst;
    wire               slv_reg_rden;
    wire               slv_reg_wren;
    reg  [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;
    reg                aw_en;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = axi_bresp;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = axi_rresp;
    assign s_axi_rvalid  = axi_rvalid;

    // 核心复位 = AXI 复位（低有效取反）| 软复位电平（zynet 顶层做法）
    assign core_rst = (~s_axi_aresetn) | soft_reset_reg;

    //----------------------------------------------------------
    // awready 生成：AWVALID&WVALID 同到时拉高一拍；单 outstanding（aw_en）
    //----------------------------------------------------------
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_awready <= 1'b0;
          aw_en <= 1'b1;
        end
      else
        begin
          if (~axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en)
            begin
              axi_awready <= 1'b1;
              aw_en <= 1'b0;
            end
            else if (s_axi_bready && axi_bvalid)
                begin
                  aw_en <= 1'b1;
                  axi_awready <= 1'b0;
                end
          else
            begin
              axi_awready <= 1'b0;
            end
        end
    end

    // 写地址锁存
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_awaddr <= 0;
        end
      else
        begin
          if (~axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en)
            begin
              axi_awaddr <= s_axi_awaddr;
            end
        end
    end

    // wready 生成（与 awready 同拍）
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_wready <= 1'b0;
        end
      else
        begin
          if (~axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en )
            begin
              axi_wready <= 1'b1;
            end
          else
            begin
              axi_wready <= 1'b0;
            end
        end
    end

    //----------------------------------------------------------
    // 寄存器写译码
    //   start_reg / w_wr_en_r 每拍默认清 0 —— 都是一拍脉冲；
    //   W_COMMIT：用自增前的旧 w_addr_reg 发写脉冲，同时 w_addr_reg+1。
    //   WSTRB 忽略（PS 恒整字写，与 zynet 一致）。
    //----------------------------------------------------------
    assign slv_reg_wren = axi_wready && s_axi_wvalid && axi_awready && s_axi_awvalid;

    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          start_reg      <= 1'b0;
          soft_reset_reg <= 1'b0;
          x_reg0 <= 16'd0;  x_reg1 <= 16'd0;  x_reg2 <= 16'd0;
          x_reg3 <= 16'd0;  x_reg4 <= 16'd0;  x_reg5 <= 16'd0;
          x_reg6 <= 16'd0;
          w_addr_reg  <= 17'd0;
          wd_reg0 <= 32'd0;  wd_reg1 <= 32'd0;  wd_reg2 <= 32'd0;
          wd_reg3 <= 32'd0;  wd_reg4 <= 32'd0;  wd_reg5 <= 32'd0;
          wd_reg6 <= 32'd0;  wd_reg7 <= 32'd0;
          w_wr_en_r   <= 1'b0;
          w_wr_addr_r <= 17'd0;
          w_wr_data_r <= 256'd0;
        end
      else
        begin
          start_reg <= 1'b0;      // 自清零：只有写 CTRL 且 bit0=1 的那拍为 1
          w_wr_en_r <= 1'b0;      // 同上，权重写脉冲只打一拍
          if (slv_reg_wren)
            begin
              case ( axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
                5'd0: begin
                          start_reg      <= s_axi_wdata[0];
                          soft_reset_reg <= s_axi_wdata[1];
                      end
                5'd2:  x_reg0 <= s_axi_wdata[15:0];
                5'd3:  x_reg1 <= s_axi_wdata[15:0];
                5'd4:  x_reg2 <= s_axi_wdata[15:0];
                5'd5:  x_reg3 <= s_axi_wdata[15:0];
                5'd6:  x_reg4 <= s_axi_wdata[15:0];
                5'd7:  x_reg5 <= s_axi_wdata[15:0];
                5'd8:  x_reg6 <= s_axi_wdata[15:0];
                5'd11: w_addr_reg <= s_axi_wdata[16:0];
                5'd12: wd_reg0 <= s_axi_wdata;
                5'd13: wd_reg1 <= s_axi_wdata;
                5'd14: wd_reg2 <= s_axi_wdata;
                5'd15: wd_reg3 <= s_axi_wdata;
                5'd16: wd_reg4 <= s_axi_wdata;
                5'd17: wd_reg5 <= s_axi_wdata;
                5'd18: wd_reg6 <= s_axi_wdata;
                5'd19: wd_reg7 <= s_axi_wdata;
                5'd20: begin
                          w_wr_en_r   <= 1'b1;
                          w_wr_addr_r <= w_addr_reg;   // 自增前的旧地址
                          w_wr_data_r <= {wd_reg7, wd_reg6, wd_reg5, wd_reg4,
                                          wd_reg3, wd_reg2, wd_reg1, wd_reg0};
                          w_addr_reg  <= w_addr_reg + 17'd1;   // 自动 +1
                       end
              endcase
            end
        end
    end

    // 写响应（恒 OKAY）
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_bvalid  <= 0;
          axi_bresp   <= 2'b0;
        end
      else
        begin
          if (axi_awready && s_axi_awvalid && ~axi_bvalid && axi_wready && s_axi_wvalid)
            begin
              axi_bvalid <= 1'b1;
              axi_bresp  <= 2'b0; // 'OKAY'
            end
          else
            begin
              if (s_axi_bready && axi_bvalid)
                begin
                  axi_bvalid <= 1'b0;
                end
            end
        end
    end

    // arready 生成 + 读地址锁存
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_arready <= 1'b0;
          axi_araddr  <= 32'b0;
        end
      else
        begin
          if (~axi_arready && s_axi_arvalid)
            begin
              axi_arready <= 1'b1;
              axi_araddr  <= s_axi_araddr;
            end
          else
            begin
              axi_arready <= 1'b0;
            end
        end
    end

    // rvalid 生成（恒 OKAY）
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_rvalid <= 0;
          axi_rresp  <= 0;
        end
      else
        begin
          if (axi_arready && s_axi_arvalid && ~axi_rvalid)
            begin
              axi_rvalid <= 1'b1;
              axi_rresp  <= 2'b0; // 'OKAY'
            end
          else if (axi_rvalid && s_axi_rready)
            begin
              axi_rvalid <= 1'b0;
            end
        end
    end

    //----------------------------------------------------------
    // 读译码（组合）
    //----------------------------------------------------------
    assign slv_reg_rden = axi_arready & s_axi_arvalid & ~axi_rvalid;
    always @(*)
    begin
      case ( axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
        5'd0   : reg_data_out = {30'd0, soft_reset_reg, 1'b0};
        5'd1   : reg_data_out = {31'd0, core_done};
        5'd2   : reg_data_out = {16'd0, x_reg0};
        5'd3   : reg_data_out = {16'd0, x_reg1};
        5'd4   : reg_data_out = {16'd0, x_reg2};
        5'd5   : reg_data_out = {16'd0, x_reg3};
        5'd6   : reg_data_out = {16'd0, x_reg4};
        5'd7   : reg_data_out = {16'd0, x_reg5};
        5'd8   : reg_data_out = {16'd0, x_reg6};
        5'd9   : reg_data_out = core_result[31:0];
        5'd10  : reg_data_out = {{24{core_result[39]}}, core_result[39:32]};
        5'd11  : reg_data_out = {15'd0, w_addr_reg};
        5'd12  : reg_data_out = wd_reg0;
        5'd13  : reg_data_out = wd_reg1;
        5'd14  : reg_data_out = wd_reg2;
        5'd15  : reg_data_out = wd_reg3;
        5'd16  : reg_data_out = wd_reg4;
        5'd17  : reg_data_out = wd_reg5;
        5'd18  : reg_data_out = wd_reg6;
        5'd19  : reg_data_out = wd_reg7;
        default: reg_data_out = 32'd0;
      endcase
    end

    // 读数据寄存
    always @( posedge s_axi_aclk )
    begin
      if ( s_axi_aresetn == 1'b0 )
        begin
          axi_rdata  <= 0;
        end
      else
        begin
          if (slv_reg_rden)
            begin
              axi_rdata <= reg_data_out;
            end
        end
    end

    //----------------------------------------------------------
    // 被包核心
    //----------------------------------------------------------
    net_v_top #(
        .W_HEX (W_HEX),
        .B_HEX (B_HEX),
        .E_HEX (E_HEX)
    ) u_core (
        .clk       (s_axi_aclk),
        .rst       (core_rst),
        .start     (start_reg),
        .x_in_0    (x_reg0),
        .x_in_1    (x_reg1),
        .x_in_2    (x_reg2),
        .x_in_3    (x_reg3),
        .x_in_4    (x_reg4),
        .x_in_5    (x_reg5),
        .x_in_6    (x_reg6),
        .result    (core_result),
        .done      (core_done),
        .w_wr_en   (w_wr_en_r),
        .w_wr_addr (w_wr_addr_r),
        .w_wr_data (w_wr_data_r)
    );

endmodule
