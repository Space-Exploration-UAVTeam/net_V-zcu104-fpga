# weights/ — 模型同学交付的权重文件（已落位，2026-08-12）

```
layer_01_weight.txt   # 第1层 (7→512)，512 行 × 7 列
layer_02_weight.txt   # 第2层 (512→512)
...
layer_07_weight.txt   # 第7层 (512→1)，1 行 × 512 列
```

【格式约定】（已确认）
- 科学记数法，有效数字 5 位，如 `1.2345e-03`
- 每行 = 一个输出神经元的全部输入权重，形状 (out_features, in_features)，
  与 PyTorch nn.Linear 的 weight 布局一致

`golden_model/reader.py` 的 `read_weight(layer_no, rows, cols)` 直接读取。
