# biases/ — 模型同学交付的偏置文件（已落位，2026-08-12）

```
layer_01_bias.txt    # 第1层 (512 个偏置)
...
layer_07_bias.txt    # 第7层 (1 个偏置)
```

【格式约定】（已确认）
- 科学记数法，有效数字 5 位，每行一个数
- 长度 = 该层输出维度

`golden_model/reader.py` 的 `read_bias(layer_no)` 直接读取。
