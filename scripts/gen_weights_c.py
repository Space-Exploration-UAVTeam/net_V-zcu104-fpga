#!/usr/bin/env python3
# gen_weights_c.py — data/hex/weights_all.hex → weights.h（SDK 裸机用 C 数组）
#
# 用法（工作目录 RL_project）：
#   python3 scripts/gen_weights_c.py
#
# 输出：
#   sdk/src/weights.h          const uint32_t weights[82464*8]（D0 最低 32bit 在前）
#   sdk/src/weights_preview.txt 前 5 行 + 末 5 行供人眼检查
#
# 自检：写出后重新解析 weights.h 里的数组，重组 256bit 与原 hex 逐行比对，
#       不一致即报错退出。
import datetime
import os

SRC = "data/hex/weights_all.hex"
OUT_H = "sdk/src/weights.h"
OUT_PREV = "sdk/src/weights_preview.txt"
N_WORDS = 82464


def main():
    with open(SRC) as f:
        lines = [l.strip() for l in f if l.strip()]
    assert len(lines) == N_WORDS, f"行数 {len(lines)} != {N_WORDS}"

    words = []
    for i, l in enumerate(lines):
        assert len(l) == 64, f"行 {i} 长度 {len(l)} != 64"
        words.append(int(l, 16))

    # 拆 8 个 uint32，D0（最低 32bit）在前
    flat = []
    for w in words:
        for k in range(8):
            flat.append((w >> (32 * k)) & 0xFFFFFFFF)

    os.makedirs(os.path.dirname(OUT_H), exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(OUT_H, "w") as f:
        f.write("/*\n")
        f.write(" * weights.h — net_V 全网量化权重（SDK 启动时经 AXI 写入 URAM）\n")
        f.write(" *\n")
        f.write(f" * 自动生成：{stamp}，来源 {SRC}（{N_WORDS} 个 256bit 字）\n")
        f.write(" * 由 scripts/gen_weights_c.py 生成，勿手改。\n")
        f.write(" *\n")
        f.write(" * 布局：每 8 个 uint32 合成一个 256bit 字，weights[8*i+k] 是\n")
        f.write(" *       第 i 字的第 k 个 32bit（k=0 即 W_D0，最低 32bit）。\n")
        f.write(" *       C 侧加载循环：写 W_D0~D7 = weights[8i+0..7] 后写 W_COMMIT。\n")
        f.write(" */\n")
        f.write("#ifndef WEIGHTS_H\n#define WEIGHTS_H\n\n#include <stdint.h>\n\n")
        f.write(f"#define NET_V_WEIGHT_WORDS {N_WORDS}u\n\n")
        f.write(f"const uint32_t weights[{N_WORDS * 8}] = {{\n")
        for i in range(N_WORDS):
            vals = ", ".join(f"0x{flat[8*i+k]:08x}u" for k in range(8))
            f.write(f"    {vals},\n")
        f.write("};\n\n#endif /* WEIGHTS_H */\n")

    # 预览文件：前 5 字 + 末 5 字
    with open(OUT_PREV, "w") as f:
        for i in list(range(5)) + list(range(N_WORDS - 5, N_WORDS)):
            f.write(f"字 {i}: hex={lines[i]}\n")
            f.write(f"      D0~D7: " +
                    " ".join(f"0x{flat[8*i+k]:08x}" for k in range(8)) + "\n")

    # 自检：重解析 weights.h，重组 256bit 与原 hex 逐行比对
    with open(OUT_H) as f:
        txt = f.read()
    body = txt.split("= {", 1)[1].rsplit("};", 1)[0]
    vals = [v.strip().rstrip("u,") for v in body.replace("\n", "").split(",")
            if v.strip()]
    assert len(vals) == N_WORDS * 8, f"解析出 {len(vals)} 个 uint32"
    for i in range(N_WORDS):
        w = 0
        for k in range(8):
            w |= int(vals[8 * i + k], 16) << (32 * k)
        assert w == words[i], f"字 {i} 重组不一致"

    print(f"OK: {OUT_H} 写出 {N_WORDS} 字（{os.path.getsize(OUT_H)} 字节），"
          f"自检通过；预览见 {OUT_PREV}")


if __name__ == "__main__":
    main()
