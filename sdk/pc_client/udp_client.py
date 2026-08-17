#!/usr/bin/env python3
# udp_client.py — net_V ZCU104 板端 UDP 推理服务的 PC 客户端（阶段 5）
#
# 协议（全部小端，详见 docs/ethernet_protocol.md）：
#   PC→板 推理请求 36B：u32 magic=0x4E565231("NVR1") | u32 seq | 7×f32 原始输入
#   板→PC 推理应答 20B：u32 magic=0x4E565232("NVR2") | u32 seq | f32 ΔV(m/s)
#                       | u32 status(bit0=ok) | u32 infer_us
#   链路自检：发 magic=0x4E434B00 的任意包，板子原样弹回。
#
# 用法：
#   python3 udp_client.py --selftest            # 本地自检（假 socket，无需板子）
#   python3 udp_client.py ping                  # 链路自检（echo）
#   python3 udp_client.py sample                # 只跑 sample_00（期望 490.401±0.5）
#   python3 udp_client.py batch                 # 跑 pc_test_vectors.json 全部 27 组
#   python3 udp_client.py batch --board 192.168.1.10 --port 5000 --timeout 2.0
import json
import os
import socket
import struct
import sys
import time

MAGIC_INFER_REQ = 0x4E565231   # "NVR1"
MAGIC_INFER_RSP = 0x4E565232   # "NVR2"
MAGIC_ECHO = 0x4E434B00        # 链路自检：板子原样弹回

BOARD_IP = "192.168.1.10"
BOARD_PORT = 5000
DV_TOL = 0.5                   # ΔV 判定容差（m/s）——用于 sample 模式对浮点期望
DV_TOL_FIXED = 0.01            # batch 模式对定点 golden 的容差（板端应逐 bit 一致，
                               # 唯一偏差来源是 float32 传输舍入 ~1e-3 量级）

REQ_FMT = "<II7f"              # 36 字节
RSP_FMT = "<IIfII"             # 20 字节
REQ_LEN = struct.calcsize(REQ_FMT)
RSP_LEN = struct.calcsize(RSP_FMT)


def pack_infer_req(seq, raw7):
    """seq: u32；raw7: 7 个 float 原始输入（h0,I0,hf-h0,If-I0,ΔΩ,fmax,tf）"""
    assert len(raw7) == 7
    return struct.pack(REQ_FMT, MAGIC_INFER_REQ, seq & 0xFFFFFFFF,
                       *[float(v) for v in raw7])


def parse_infer_rsp(data):
    """返回 (seq, dv, status, infer_us)；包非法抛 ValueError。"""
    if len(data) != RSP_LEN:
        raise ValueError("应答长度 {} != {}".format(len(data), RSP_LEN))
    magic, seq, dv, status, infer_us = struct.unpack(RSP_FMT, data)
    if magic != MAGIC_INFER_RSP:
        raise ValueError("应答 magic 0x{:08X} 非法".format(magic))
    return seq, dv, status, infer_us


def pack_echo(seq, payload=b"NCK"):
    """链路自检包：magic=0x4E434B00 | seq | 任意 payload。"""
    return struct.pack("<II", MAGIC_ECHO, seq & 0xFFFFFFFF) + payload


# ----------------------------------------------------------------------
# 以下用到真实 socket 的部分独立出来，便于 --selftest 用假 socket 替换
# ----------------------------------------------------------------------
def udp_roundtrip(sock, addr, req, timeout):
    """发 req 到 addr，等应答，返回 (data, rtt_us)；超时返回 (None, None)。"""
    sock.settimeout(timeout)
    t0 = time.perf_counter()
    sock.sendto(req, addr)
    try:
        data, _ = sock.recvfrom(2048)
    except socket.timeout:
        return None, None
    rtt_us = (time.perf_counter() - t0) * 1e6
    return data, rtt_us


def cmd_ping(board, port, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ok = 0
    for i in range(4):
        req = pack_echo(i, b"link-check-%d" % i)
        data, rtt = udp_roundtrip(sock, (board, port), req, timeout)
        if data == req:
            print("echo {}: OK rtt={:.0f}us".format(i, rtt))
            ok += 1
        else:
            print("echo {}: FAIL（{}）".format(i, "超时" if data is None
                                               else "内容被改动"))
    print("链路自检 {}/4 通过".format(ok))
    return 0 if ok == 4 else 1


def run_vectors(sock, board, port, timeout, vectors, verbose=True):
    """跑一组向量，返回 (n_pass, n_fail, [(name, dv, exp, ok, infer_us, rtt_us)])"""
    n_pass = n_fail = 0
    rows = []
    for seq, v in enumerate(vectors):
        data, rtt = udp_roundtrip(sock, (board, port),
                                  pack_infer_req(seq, v["raw"]), timeout)
        if data is None:
            n_fail += 1
            rows.append((v["name"], None, v["dv_float"], False, None, None))
            print("FAIL {}: 超时无应答".format(v["name"]))
            continue
        try:
            seq_r, dv, status, infer_us = parse_infer_rsp(data)
        except ValueError as e:
            n_fail += 1
            rows.append((v["name"], None, v["dv_float"], False, None, rtt))
            print("FAIL {}: {}".format(v["name"], e))
            continue
        err = abs(dv - v["dv_float"])            # 与浮点期望的差（信息展示）
        err_fixed = abs(dv - v.get("dv_fixed", v["dv_float"]))  # 与定点 golden 的差（判定）
        ok = (seq_r == seq) and (status & 1) and err_fixed < DV_TOL_FIXED
        if ok:
            n_pass += 1
        else:
            n_fail += 1
        rows.append((v["name"], dv, v["dv_float"], ok, infer_us, rtt))
        if verbose or not ok:
            print("{} {}: ΔV={:.3f} 定点期望={:.3f} err={:.4f} 浮点期望={:.3f} "
                  "err_float={:.3f} infer={}us rtt={:.0f}us {}".format(
                      "PASS" if ok else "FAIL", v["name"], dv,
                      v.get("dv_fixed", v["dv_float"]), err_fixed,
                      v["dv_float"], err, infer_us, rtt,
                      "" if ok else "(seq={} status={})".format(seq_r,
                                                                status)))
    return n_pass, n_fail, rows


def cmd_sample(board, port, timeout):
    vec = {"name": "s00_sample_00",
           "raw": [7.5784e2, 1.0608e0, 4.1086e1, 3.4237e-2,
                   -2.4982e0, 2.5000e-3, 3.4560e6],
           "dv_float": 490.4415}   # 浮点前向期望；定点 golden 为 490.4013
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    n_pass, n_fail, _ = run_vectors(sock, board, port, timeout, [vec])
    print("sample_00: {}".format("PASS" if n_pass == 1 else "FAIL"))
    return 0 if n_pass == 1 else 1


def cmd_batch(board, port, timeout, json_path):
    with open(json_path) as f:
        vectors = json.load(f)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t0 = time.perf_counter()
    n_pass, n_fail, rows = run_vectors(sock, board, port, timeout, vectors)
    dt = time.perf_counter() - t0
    infers = [r[4] for r in rows if r[4] is not None]
    rtts = [r[5] for r in rows if r[5] is not None]
    print("-" * 60)
    print("批量 {} 组：PASS {} / FAIL {}，总耗时 {:.2f}s".format(
        len(vectors), n_pass, n_fail, dt))
    if infers:
        print("板端推理 infer_us: min={} max={} avg={:.0f} us".format(
            min(infers), max(infers), sum(infers) / len(infers)))
    if rtts:
        print("UDP 往返 rtt: min={:.0f} max={:.0f} avg={:.0f} us".format(
            min(rtts), max(rtts), sum(rtts) / len(rtts)))
    return 0 if n_fail == 0 else 1


def cmd_run(board, port, timeout, raw7):
    """自定义输入验证：run h0 I0 Δh ΔI ΔΩ fmax tf（7 个 float，原始物理量）。"""
    vec = {"name": "custom", "raw": raw7, "dv_float": 0.0}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    data, rtt = udp_roundtrip(sock, (board, port),
                              pack_infer_req(0, vec["raw"]), timeout)
    if data is None:
        print("超时无应答")
        return 1
    seq_r, dv, status, infer_us = parse_infer_rsp(data)
    print("板端应答：ΔV = {:.3f} m/s   推理 {} us   往返 {:.0f} us   "
          "status={}".format(dv, infer_us, rtt, status))
    print("（期望值请与 golden model 浮点前向对比，见 README）")
    return 0


# ----------------------------------------------------------------------
# 本地自检：假 socket 模拟板子（原样 echo / 按协议回复固定 ΔV）
# ----------------------------------------------------------------------
class FakeBoardSocket:
    def __init__(self):
        self.sent = []
        self.dv = 490.4013

    def settimeout(self, t):
        pass

    def sendto(self, data, addr):
        self.sent.append(data)

    def recvfrom(self, n):
        req = self.sent.pop()
        magic, seq = struct.unpack("<II", req[:8])
        if magic == MAGIC_ECHO:
            return req, ("board", 5000)                      # 原样弹回
        assert magic == MAGIC_INFER_REQ
        assert len(req) == REQ_LEN
        rsp = struct.pack(RSP_FMT, MAGIC_INFER_RSP, seq,
                          self.dv, 1, 826)                   # status=1
        return rsp, ("board", 5000)


def selftest():
    """打包/解包/echo/批量流程自检（不碰真实网络）。"""
    n_err = 0

    def check(name, cond, detail=""):
        nonlocal n_err
        if not cond:
            n_err += 1
        print("  [{}] {} {}".format("PASS" if cond else "FAIL", name, detail))

    # 1. 打包格式：长度 + 小端字节序 + 字段位置
    req = pack_infer_req(0x12345678, [1.5, -2.25, 0.0, 100.0,
                                      3.456e6, -0.1, 800.0])
    check("请求 36 字节", len(req) == REQ_LEN)
    check("magic 小端", req[:4] == b"\x31\x52\x56\x4E")
    check("seq 小端", req[4:8] == b"\x78\x56\x34\x12")
    check("float[0]=1.5 小端", req[8:12] == struct.pack("<f", 1.5))
    check("float[6]=800 小端", req[32:36] == struct.pack("<f", 800.0))

    # 2. 应答解包 + 非法包拒绝
    rsp = struct.pack(RSP_FMT, MAGIC_INFER_RSP, 7, 490.4013, 1, 826)
    seq, dv, status, us = parse_infer_rsp(rsp)
    check("应答解包", (seq, status, us) == (7, 1, 826)
          and abs(dv - 490.4013) < 1e-3)
    for bad in (b"", rsp[:19], struct.pack(RSP_FMT, 0xDEAD, 0, 0.0, 0, 0)):
        try:
            parse_infer_rsp(bad)
            check("拒绝非法包 %dB" % len(bad), False)
        except ValueError:
            check("拒绝非法包 %dB" % len(bad), True)

    # 3. echo 打包
    e = pack_echo(3, b"abc")
    check("echo 包格式", e[:8] == struct.pack("<II", MAGIC_ECHO, 3)
          and e[8:] == b"abc")

    # 4. 假板子全流程：ping + sample + 26 组批量（ΔV 恒定→看比对逻辑）
    fake = FakeBoardSocket()
    check("假板 echo", udp_roundtrip(fake, None, pack_echo(0, b"x"), 0)[0]
          == pack_echo(0, b"x"))
    vecs = [{"name": "v%02d" % i,
             "raw": [7.5784e2, 1.0608, 41.086, 0.034237,
                     -2.4982, 2.5e-3, 3.456e6],
             "dv_float": 490.4415,
             "dv_fixed": 490.4013} for i in range(27)]   # 假板返回定点值
    n_pass, n_fail, rows = run_vectors(fake, None, 0, 0.1, vecs,
                                       verbose=False)
    check("假板批量 27 组全过（容差内）", n_pass == 27 and n_fail == 0)

    fake2 = FakeBoardSocket()
    fake2.dv = 9999.0       # 板上算错的情形
    n_pass, n_fail, _ = run_vectors(fake2, None, 0, 0.1, vecs[:3],
                                    verbose=False)
    check("假板算出错误值 → 全 FAIL", n_pass == 0 and n_fail == 3)

    print("selftest: {}".format("ALL PASS" if n_err == 0
                                  else "%d FAILURES" % n_err))
    return 0 if n_err == 0 else 1


def main():
    argv = sys.argv[1:]
    board = BOARD_IP
    port = BOARD_PORT
    timeout = 2.0
    json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "pc_test_vectors.json")
    cmd = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--selftest":
            return selftest()
        elif a == "--board":
            board = argv[i + 1]; i += 1
        elif a == "--port":
            port = int(argv[i + 1]); i += 1
        elif a == "--timeout":
            timeout = float(argv[i + 1]); i += 1
        elif a == "--vectors":
            json_path = argv[i + 1]; i += 1
        elif a == "run":
            cmd = a
            if i + 7 >= len(argv) + 1:
                pass
            try:
                raw7 = [float(x) for x in argv[i + 1:i + 8]]
            except (ValueError, IndexError):
                print("用法: run h0 I0 Δh ΔI ΔΩ fmax tf  （7 个浮点数）")
                return 2
            if len(raw7) != 7:
                print("run 需要 7 个浮点数")
                return 2
            i += 7
            return cmd_run(board, port, timeout, raw7)
        elif a in ("ping", "sample", "batch"):
            cmd = a
        else:
            print("未知参数: {}".format(a))
            return 2
        i += 1

    if cmd == "ping":
        return cmd_ping(board, port, timeout)
    if cmd == "sample":
        return cmd_sample(board, port, timeout)
    if cmd == "batch":
        return cmd_batch(board, port, timeout, json_path)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
