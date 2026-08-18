/*****************************************************************************/
/*
 * main.c — net_V ZCU104 裸机推理 + UDP 服务（standalone BSP + lwIP2.0.2 raw，
 *          A53 core0）
 *
 * 硬件：Block Design 里 PS 经 M_AXI_HPM0_FPD 挂 net_v_axi IP
 *       （基址 0xA000_0000，AXI 时钟 pl_clk0 100MHz）；GEM3 走 MIO RGMII
 *       到板上 PHY（板级预设已配好）。UDP 服务端：固定 IP 192.168.1.10，
 *       端口 5000；PC（192.168.1.100）是客户端（替身主机）。
 *
 * 启动顺序：权重加载（URAM 上电空白，必须先做）→ 软复位演示 →
 *   sample_00 串口自检（不依赖网络）→ 网络初始化（TTC/GIC + lwIP）→
 *   主循环（xemacif_input 收包）。
 *
 * UDP 协议（全部小端，字段细节见 docs/ethernet_protocol.md）：
 *   PC→板 推理请求 36B：u32 magic=0x4E565231("NVR1") | u32 seq |
 *                       7×f32 原始输入（h0,I0,hf-h0,If-I0,ΔΩ,fmax,tf）
 *   板→PC 推理应答 20B：u32 magic=0x4E565232("NVR2") | u32 seq |
 *                       f32 ΔV(m/s) | u32 status(bit0=ok) | u32 infer_us
 *   链路自检：magic=0x4E434B00 的包原样弹回（任意长度，≤255B）。
 *
 * 归一化精度说明（为什么用 double）：
 *   z=(x-mean)/sqrt(var)。float32 在最坏特征 tf≈3.46e6 下 z 误差
 *   ~1.4e-7，比 Q6.10 半 LSB（4.9e-4）低 4 个数量级，float 也够；
 *   但 A53 有硬件 FP64，double 零代价，彻底无争议。量化用 numpy round
 *   语义（half-to-even），与 golden model 逐 bit 一致（sample_00 的
 *   7 个 int16 与 data/vectors/inputs.hex 行 0 完全相等，已验证）。
 *   inv_std 离线预计算成 double 常量，运行时不依赖 libm。
 *
 * 网络部分骨架沿用 Xilinx lwip_echo_server 模板（platform_zynqmp.c 原样
 * 引用）：TTC0 周期中断跑 eth_link_detect，GIC 由平台代码初始化，
 * EMAC 中断由 lwIP 端口层（xemacpsif）自己注册。
 */
/*****************************************************************************/

#include <stdint.h>
#include <string.h>

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xtime_l.h"

#include "netif/xadapter.h"
#include "lwip/init.h"
#include "lwip/udp.h"

#include "platform.h"
#include "platform_config.h"

#include "weights.h"

/*========================= net_V 寄存器（AXI4-Lite） ======================*/
#define NETV_BASE        0xA0000000U
#define REG_CTRL         (NETV_BASE + 0x00)
#define REG_STATUS       (NETV_BASE + 0x04)
#define REG_X0           (NETV_BASE + 0x08)   /* X1 = +0x0C ... X6 = +0x20 */
#define REG_RESULT_LO    (NETV_BASE + 0x24)
#define REG_RESULT_HI    (NETV_BASE + 0x28)
#define REG_W_ADDR       (NETV_BASE + 0x2C)
#define REG_W_D0         (NETV_BASE + 0x30)   /* W_D1=+0x34 ... W_D7=+0x4C */
#define REG_W_COMMIT     (NETV_BASE + 0x50)

#define CTRL_START       0x1u   /* bit0：start 自清零脉冲 */
#define CTRL_SOFT_RST    0x2u   /* bit1：软复位电平 */

#define DONE_POLL_LIMIT  100000000u  /* done 轮询上限（推理约 0.83ms@100MHz）*/

#ifndef COUNTS_PER_SECOND
#define COUNTS_PER_SECOND 100000000ULL  /* 兜底：仅影响耗时打印/打点 */
#endif

/*========================= sample_00 数据（串口自检用） ===================*/
/* 原始 7 维输入（input_raw.txt）：顺序 h0, I0, hf-h0, If-I0, ΔΩ, fmax, tf */
static const double sample00_raw[7] = {
    7.5784e2, 1.0608e0, 4.1086e1, 3.4237e-2, -2.4982e0, 2.5000e-3, 3.4560e6
};

/* 归一化参数（训练集统计，v2 双精度交付为准，2026-08-15 更新；
 * v1 txt 是同一统计量的 5 位舍入版，差异对 Q6.10 量化无影响） */
static const double feat_mean[7] = {
    591.4182045417623, 1.2184900023224592, 0.5947851603496672,
    0.0005838004451228998, -0.8538870838842224, 0.0027806010304868706,
    1824750.1096800924
};
/* inv_std[j] = 1/sqrt(var[j])，v2 的 VAR = [53181.20145531056,
 *   0.008572358358327323, 61759.02668368359, 0.0020139235748715296,
 *   0.5889048745996855, 1.6687917119950896e-06, 3283735541737.478]，
 *   离线按 double 预算 */
static const double feat_inv_std[7] = {
    0.0043363160471822084, 10.80064871230099, 0.0040239240828261573,
    22.283248685592664, 1.3030990417413308, 774.10332505181805,
    5.5184347675533539e-07
};

/* sample_00 期望量化输入（inputs.hex 行 0，有符号十进制） */
static const int16_t sample00_q_exp[7] = {
    739, -1744, 167, 768, -2194, -222, 922
};
/* 期望 40bit 累加器（expected.hex 行 0，v2 权重）：ΔV=490.4064 m/s */
#define EXP_ACC       0x001ea68081LL
#define EXP_DV_MILLI  490406LL    /* 490.4064 m/s，单位 0.001 m/s */
#define DV_TOL_MILLI  500LL       /* 判定容差 0.5 m/s */

/*========================= 权重加载 ====================================*/
static void load_weights(void)
{
    uint32_t i;
    int k;
    XTime t0, t1;
    uint64_t ms;

    XTime_GetTime(&t0);
    Xil_Out32(REG_W_ADDR, 0u);          /* 首字地址 0；之后 W_COMMIT 自动 +1 */
    for (i = 0; i < NET_V_WEIGHT_WORDS; i++) {
        const uint32_t *w = &weights[i * 8];
        for (k = 0; k < 8; k++)
            Xil_Out32(REG_W_D0 + 4 * k, w[k]);
        Xil_Out32(REG_W_COMMIT, 0u);
    }
    XTime_GetTime(&t1);
    ms = (uint64_t)(t1 - t0) * 1000u / COUNTS_PER_SECOND;
    xil_printf("weights loaded: %u words x 256bit, %lu ms\r\n",
               (unsigned int)NET_V_WEIGHT_WORDS, (unsigned long)ms);
}

/*========================= 归一化 + 量化 ================================*/
/* z → Q6.10 int16：round(z*1024)（half-to-even）+ int16 饱和。
 * |z|<<32，v=z*1024 在 int64 安全范围内，可放心截断取整。 */
static int16_t quantize_q6p10(double z)
{
    double v = z * 1024.0;
    int64_t trunc_v = (int64_t)v;                       /* 向零截断 */
    double floor_v = (v < 0.0 && (double)trunc_v != v)
                     ? (double)(trunc_v - 1) : (double)trunc_v;
    double frac = v - floor_v;                          /* ∈ [0,1) */
    int64_t fi = (int64_t)floor_v;
    int64_t r;

    if (frac > 0.5)       r = fi + 1;
    else if (frac < 0.5)  r = fi;
    else                  r = (fi & 1) ? fi + 1 : fi;   /* 恰 .5 → 取偶数 */

    if (r > 32767)  r = 32767;
    if (r < -32768) r = -32768;
    return (int16_t)r;
}

/* 原始 7 维（double）→ z → Q6.10 int16 */
static void normalize_and_quantize(const double raw[7], int16_t q[7])
{
    int j;
    for (j = 0; j < 7; j++)
        q[j] = quantize_q6p10((raw[j] - feat_mean[j]) * feat_inv_std[j]);
}

/*========================= 推理 ========================================*/
/* 返回 0=成功/-1=超时；acc40 = layer_07 累加器原值（acc_frac=20 刻度）；
 * infer_us（可空）= PL 推理微秒数（XTime 打点：发 start 到 done 拉高） */
static int run_inference(const int16_t q[7], int64_t *acc40,
                         uint32_t *infer_us)
{
    int j;
    uint32_t poll = 0;
    uint32_t lo, hi;
    uint64_t u;
    XTime t0, t1;

    for (j = 0; j < 7; j++)
        Xil_Out32(REG_X0 + 4 * j, (uint32_t)(uint16_t)q[j]);

    XTime_GetTime(&t0);
    Xil_Out32(REG_CTRL, CTRL_START);      /* start 自清零脉冲 */

    while ((Xil_In32(REG_STATUS) & 1u) == 0u) {
        if (++poll > DONE_POLL_LIMIT)
            return -1;                     /* 超时 */
    }
    XTime_GetTime(&t1);
    if (infer_us)
        *infer_us = (uint32_t)((uint64_t)(t1 - t0) * 1000000ULL /
                               COUNTS_PER_SECOND);

    lo = Xil_In32(REG_RESULT_LO);
    hi = Xil_In32(REG_RESULT_HI);
    u = ((uint64_t)(hi & 0xFFu) << 32) | (uint64_t)lo;   /* 拼 40bit */
    *acc40 = (int64_t)u;
    if (*acc40 & (1LL << 39))
        *acc40 -= (1LL << 40);                           /* 40bit 符号扩展 */
    return 0;
}

/*========================= 串口自检（不依赖网络） ======================*/
static int selftest_sample00(void)
{
    int16_t q[7];
    int64_t acc;
    int64_t dv_milli, err_milli;
    uint32_t us;
    int j, q_ok, bit_exact;

    /* 软复位演示：CTRL.bit1 拉高再拉低，done 随之清零 */
    Xil_Out32(REG_CTRL, CTRL_SOFT_RST);
    Xil_Out32(REG_CTRL, 0u);
    xil_printf("soft_reset done=%lu（应为 0）\r\n",
               (unsigned long)(Xil_In32(REG_STATUS) & 1u));

    /* 量化自检（逐特征比对 inputs.hex 行 0） */
    normalize_and_quantize(sample00_raw, q);
    q_ok = 1;
    for (j = 0; j < 7; j++) {
        if (q[j] != sample00_q_exp[j])
            q_ok = 0;
        xil_printf("x%d: q=%d 期望 %d %s\r\n", j, q[j], sample00_q_exp[j],
                   (q[j] == sample00_q_exp[j]) ? "OK" : "MISMATCH");
    }

    if (run_inference(q, &acc, &us) != 0) {
        xil_printf("SELFTEST FAIL: done 超时\r\n");
        return -1;
    }

    dv_milli = (acc * 1000LL) / 1048576LL;   /* xil_printf 不支持 %f */
    err_milli = dv_milli - EXP_DV_MILLI;
    if (err_milli < 0)
        err_milli = -err_milli;
    bit_exact = (acc == EXP_ACC);

    xil_printf("acc7 = 0x%08lx%08lx（期望 0x%08lx%08lx）%s\r\n",
               (unsigned long)((uint64_t)acc >> 32),
               (unsigned long)(uint32_t)acc,
               (unsigned long)((uint64_t)EXP_ACC >> 32),
               (unsigned long)(uint32_t)EXP_ACC,
               bit_exact ? " bit-true" : "");
    xil_printf("ΔV = %ld.%03ld m/s，期望 %ld.%03ld，误差 %ld.%03ld m/s"
               "，推理 %lu us\r\n",
               (long)(dv_milli / 1000), (long)(dv_milli % 1000),
               (long)(EXP_DV_MILLI / 1000), (long)(EXP_DV_MILLI % 1000),
               (long)(err_milli / 1000), (long)(err_milli % 1000),
               (unsigned long)us);

    if (q_ok && err_milli < DV_TOL_MILLI) {
        xil_printf("SELFTEST PASS%s\r\n",
                   bit_exact ? "（与 golden 逐 bit 一致）" : "");
        return 0;
    }
    xil_printf("SELFTEST FAIL\r\n");
    return -1;
}

/*========================= UDP 服务 ====================================*/
#define NETV_UDP_PORT    5000u
#define BOARD_IP0 192
#define BOARD_IP1 168
#define BOARD_IP2 1
#define BOARD_IP3 10
#define BOARD_GW0 192
#define BOARD_GW1 168
#define BOARD_GW2 1
#define BOARD_GW3 1
#define BOARD_NM0 255
#define BOARD_NM1 255
#define BOARD_NM2 255
#define BOARD_NM3 0

#define MAGIC_INFER_REQ  0x4E565231u   /* "NVR1"：推理请求 */
#define MAGIC_INFER_RSP  0x4E565232u   /* "NVR2"：推理应答 */
#define MAGIC_ECHO       0x4E434B00u   /* 链路自检：原样弹回 */

#pragma pack(push, 1)
typedef struct {                        /* PC→板，36 字节 */
    uint32_t magic;
    uint32_t seq;
    float    x[7];                      /* 原始输入（未归一化） */
} infer_req_t;
typedef struct {                        /* 板→PC，20 字节 */
    uint32_t magic;
    uint32_t seq;
    float    dv;                        /* ΔV，单位 m/s */
    uint32_t status;                    /* bit0=ok（推理完成） */
    uint32_t infer_us;                  /* PL 推理微秒数 */
} infer_rsp_t;
#pragma pack(pop)

/* 编译期尺寸断言（协议文档与代码必须一致） */
typedef char req_size_check[(sizeof(infer_req_t) == 36) ? 1 : -1];
typedef char rsp_size_check[(sizeof(infer_rsp_t) == 20) ? 1 : -1];

static struct netif server_netif;
struct netif *echo_netif;               /* platform_zynqmp.c 引用此名 */

static uint32_t g_n_infer, g_n_echo, g_n_bad;

/* UDP 收包回调（在 xemacif_input 上下文里跑，可阻塞做推理） */
static void udp_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                        const ip_addr_t *addr, u16_t port)
{
    uint8_t buf[64];
    uint16_t n;
    uint32_t magic;

    (void)arg;
    if (p == NULL)
        return;

    /* 包都很小（≤36B），但 pbuf 可能链式——统一拷到本地再看 */
    n = (p->tot_len < sizeof(buf)) ? p->tot_len : (uint16_t)sizeof(buf);
    pbuf_copy_partial(p, buf, n, 0);

    if (n < 4u) {
        g_n_bad++;
        goto out;
    }
    memcpy(&magic, buf, 4);             /* 小端 u32 */

    if (magic == MAGIC_ECHO) {
        /* 链路自检：原样弹回（含 magic/seq/payload 全部字节） */
        struct pbuf *q = pbuf_alloc(PBUF_TRANSPORT, n, PBUF_RAM);
        if (q != NULL) {
            memcpy(q->payload, buf, n);
            udp_sendto(pcb, q, addr, port);
            pbuf_free(q);
            g_n_echo++;
            if ((g_n_echo & 0x3Fu) == 1u)
                xil_printf("echo #%lu\r\n", (unsigned long)g_n_echo);
        }
    } else if (magic == MAGIC_INFER_REQ) {
        if (n == sizeof(infer_req_t)) {
            infer_req_t req;
            infer_rsp_t rsp;
            double raw[7];
            int16_t q[7];
            int64_t acc = 0;
            int j, rc;
            struct pbuf *qbuf;

            memcpy(&req, buf, sizeof(req));
            for (j = 0; j < 7; j++)
                raw[j] = (double)req.x[j];   /* f32 → double 再归一化 */
            normalize_and_quantize(raw, q);
            rc = run_inference(q, &acc, &rsp.infer_us);

            rsp.magic = MAGIC_INFER_RSP;
            rsp.seq = req.seq;
            rsp.status = (rc == 0) ? 1u : 0u;
            rsp.dv = (rc == 0) ? (float)((double)acc / 1048576.0) : 0.0f;

            qbuf = pbuf_alloc(PBUF_TRANSPORT, sizeof(rsp), PBUF_RAM);
            if (qbuf != NULL) {
                memcpy(qbuf->payload, &rsp, sizeof(rsp));
                udp_sendto(pcb, qbuf, addr, port);
                pbuf_free(qbuf);
            }
            g_n_infer++;
            if ((g_n_infer & 0x3Fu) == 1u)
                xil_printf("infer #%lu seq=%lu ΔV=%ld.%03ld m/s %lu us\r\n",
                           (unsigned long)g_n_infer,
                           (unsigned long)req.seq,
                           (long)(acc / 1048576LL),
                           (long)((acc * 1000LL / 1048576LL) % 1000),
                           (unsigned long)rsp.infer_us);
        } else {
            g_n_bad++;
            xil_printf("bad infer req len=%u（期望 %u）\r\n",
                       (unsigned int)n, (unsigned int)sizeof(infer_req_t));
        }
    } else {
        g_n_bad++;
        if ((g_n_bad & 0x3Fu) == 1u)
            xil_printf("unknown magic 0x%08lx（累计 %lu）\r\n",
                       (unsigned long)magic, (unsigned long)g_n_bad);
    }
out:
    pbuf_free(p);
}

/* 网络初始化（固定 IP，无 DHCP）；返回 0 成功 */
static int network_init(void)
{
    ip_addr_t ipaddr, netmask, gw;
    /* MAC 地址：Xilinx OUI 00:0a:35 + 板序号；多块板同时上链要改 */
    unsigned char mac[] = { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };
    struct udp_pcb *pcb;

    IP4_ADDR(&ipaddr,  BOARD_IP0, BOARD_IP1, BOARD_IP2, BOARD_IP3);
    IP4_ADDR(&netmask, BOARD_NM0, BOARD_NM1, BOARD_NM2, BOARD_NM3);
    IP4_ADDR(&gw,      BOARD_GW0, BOARD_GW1, BOARD_GW2, BOARD_GW3);

    init_platform();              /* TTC0 周期定时 + GIC（platform_zynqmp.c） */
    lwip_init();

    echo_netif = &server_netif;
    if (xemac_add(echo_netif, &ipaddr, &netmask, &gw, mac,
                  PLATFORM_EMAC_BASEADDR) == NULL) {
        xil_printf("ERROR: xemac_add 失败\r\n");
        return -1;
    }
    netif_set_default(echo_netif);
    platform_enable_interrupts(); /* 开 IRQ（EMAC 中断由 lwIP 端口层自注册） */
    netif_set_up(echo_netif);

    pcb = udp_new();                    /* lwip 2.0.2：没有 udp_create */
    if (pcb == NULL) {
        xil_printf("ERROR: udp_new 失败\r\n");
        return -1;
    }
    if (udp_bind(pcb, IP_ADDR_ANY, (u16_t)NETV_UDP_PORT) != ERR_OK) {
        xil_printf("ERROR: udp_bind 失败\r\n");
        return -1;
    }
    udp_recv(pcb, udp_recv_cb, NULL);

    xil_printf("UDP 服务就绪：%d.%d.%d.%d:%u（lwIP raw，无 DHCP）\r\n",
               BOARD_IP0, BOARD_IP1, BOARD_IP2, BOARD_IP3,
               (unsigned int)NETV_UDP_PORT);
    return 0;
}

/*========================= 主流程 ======================================*/
int main(void)
{
    xil_printf("\r\n===== net_V ZCU104 裸机推理 + UDP 服务 =====\r\n");

    /* 1. 权重加载（URAM 上电空白，必须最先做） */
    load_weights();

    /* 2. 串口自检（sample_00，不依赖网络） */
    if (selftest_sample00() != 0) {
        xil_printf("自检失败，不启动网络服务。请检查 PL 配置与权重。\r\n");
        for (;;)
            ;
    }

    /* 3. 网络初始化 + UDP 服务 */
    if (network_init() != 0) {
        xil_printf("网络初始化失败，停留在串口模式。\r\n");
        for (;;)
            ;
    }

    /* 4. 主循环：收包。本端口配置 NO_SYS_NO_TIMERS=1（Xilinx raw 模式惯例，
     *    lwIP 内部超时系统关闭，sys_check_timeouts 不编进库里），ARP 表项
     *    不老化——直连场景无碍；链路状态由 TTC 周期跑 eth_link_detect。 */
    for (;;) {
        xemacif_input(echo_netif);
    }

    /* never reached */
    cleanup_platform();
    return 0;
}
