# test_samples/ — 模型同学交付的测试样本 golden vector（已落位，2026-08-12）

```
sample_00/
├── input_raw.txt           # 原始输入（7 个数，未归一化）
├── input_normalized.txt    # 归一化输入（7 个数）
├── layer_01_output.txt     # 第1层输出 (512 个数)
...
└── layer_07_output.txt     # 第7层输出 (1 个数，即最终 ΔV)
```

【格式约定】（已确认）
- 科学记数法，有效数字 5 位，空格分隔
- 归一化公式：z = (x - mean) / √var，参数见 `data/net_V_input_normalization.txt`

【用途】这是**天然的 golden vector**：
- `tests/test_golden_model.py` 已用它做逐层浮点对比（max abs err ≤ 5e-2）
- 后续每实现一层 RTL，就能用它对这一层做自动比对
