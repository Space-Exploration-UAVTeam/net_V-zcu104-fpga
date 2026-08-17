# data/hex — RTL ROM 初始化文件

由 `scripts/gen_hex.py` 从 golden model 的 bit-true 定点缓存导出（与
`docs/fixed_point_spec.md` 语义一致，生成时带逐值回读自检）。
**改 Q 格式 / 层结构 / 权重数据后必须重新生成。**

## weights_all.hex（82464 行 × 64 hex 字符 = 256bit/行）

全部 7 层权重的统一 ROM 映像，`rtl/weight_rom.v` 用 `$readmemh` 载入。

- 每行一个 256bit 字 = 16 条 lane 的 int16 补码：
  字内 bit[16k+15:16k] = lane k（hex 串最右 4 字符 = lane 0）
- lane k 对应输入元素 `a[16*t + k]`（t = 组号）
- 字地址 = `w_base[层] + 神经元号 j × NG + 组号 t`
  （"输出神经元连续"：同一神经元的 NG 个字地址连续；
  NG = ceil(in_dim/16)，layer_01 为 1，其余层为 32）
- layer_01 只有 7 个有效输入，lane 7..15 权重补 0（RTL 侧 act_buf[7..15]
  装载时也清 0，双保险）

| 层 | w_base | 字数 | 层 | w_base | 字数 |
|---|---|---|---|---|---|
| 1 | 0 | 512 | 5 | 49664 | 16384 |
| 2 | 512 | 16384 | 6 | 66048 | 16384 |
| 3 | 16896 | 16384 | 7 | 82432 | 32 |
| 4 | 33280 | 16384 | 合计 | — | 82464 |

## bias_all.hex（3073 行 × 10 hex 字符 = 40bit/行）

各层 bias，按该层 `acc_frac = w_frac + x_frac` 量化（规则①）。
地址 = `b_base[层] + 神经元号 j`。
b_base：layer_01=0, 02=512, 03=1024, 04=1536, 05=2048, 06=2560, 07=3072。

## elu_lut.hex（1157 行 × 4 hex 字符 = int16/行）

ELU 负支查找表（`golden_model/elu_lut.py::build_elu_lut` 同源），
5 张去重表（layer_04 与 layer_06 同为 f=5，共享）：

| act_frac f | 基址 | 表项数 | 插值位数 IB |
|---|---|---|---|
| 12 | 0 | 257 | 7 |
| 10 | 257 | 257 | 5 |
| 7 | 514 | 257 | 2 |
| 5 | 771 | 257 | 0（精确查表） |
| 4 | 1028 | 129 | 0（精确查表） |
