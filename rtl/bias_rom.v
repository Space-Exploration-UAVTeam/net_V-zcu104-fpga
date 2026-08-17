`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// bias_rom.v — 全网偏置 ROM（40bit 字，acc_frac 刻度）
//
// 功能：存全部 7 层的量化 bias（规则①量化到各层 acc_frac = w_frac+x_frac，
//       见 fixed_point_spec.md §3），同步读（1 拍延迟）。
//       bias 在神经元最后一组累加完之后才加进累加器（见 fc_engine.v BIAS 级）。
//
// 地址 = b_base[层] + 神经元号 j：
//   layer_01=0  layer_02=512  layer_03=1024  layer_04=1536
//   layer_05=2048  layer_06=2560  layer_07=3072  共 3073 字
// （由 scripts/gen_hex.py 生成并自检）
//
// HEX_FILE 默认路径相对 RL_project 根目录。
//////////////////////////////////////////////////////////////////////////////

module bias_rom #(
    parameter HEX_FILE = "data/hex/bias_all.hex",
    parameter DEPTH    = 3073,         // 512×6 + 1
    parameter ADDR_W   = 12            // 2^12 = 4096 ≥ 3073
)(
    input  wire               clk,
    input  wire [ADDR_W-1:0]  addr,
    output reg  signed [39:0] q        // bias（40bit 有符号，acc 刻度）
);

    (* ram_style = "block" *) reg [39:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(HEX_FILE, mem);
    end

    always @(posedge clk) begin
        q <= mem[addr];
    end

endmodule
