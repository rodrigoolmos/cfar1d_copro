// Copyright (c) 2011-2025 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define NSAMPLES 4096u
#define NREPS      16u
#define MAXW      64u
#define NSEEDS      8u

typedef struct {
    uint32_t alpha;
    uint32_t tl;
    uint32_t tr;
    uint32_t gl;
    uint32_t gr;
    const char *name;
} cfar_cfg_t;

static const cfar_cfg_t kCfgs[] = {
    {3u, 4u, 4u, 1u, 1u, "base"},
    {2u, 6u, 6u, 1u, 1u, "wide_train_low_alpha"},
    {4u, 8u, 8u, 2u, 2u, "wide_guard_high_alpha"},
    {5u, 10u, 6u, 2u, 1u, "asymmetric_high_alpha"},
    {1u, 12u, 12u, 3u, 3u, "very_permissive"},
    {6u, 5u, 15u, 1u, 2u, "asymmetric_strict"},
    {0u, 0u, 0u, 0u, 0u, "min_window_alpha0"},
    {7u, 0u, 0u, 0u, 0u, "min_window_alpha7"},
    {3u, 30u, 30u, 1u, 2u, "max_window_balanced"},
    {2u, 31u, 28u, 2u, 2u, "max_window_asymmetric"},
    {3u, 2u, 2u, 20u, 20u, "wide_guard_small_train"},
    {4u, 20u, 20u, 0u, 0u, "high_train_no_guard"},
    {3u, 0u, 16u, 1u, 1u, "right_train_only"},
    {3u, 16u, 0u, 1u, 1u, "left_train_only"}
};

static const uint64_t kSeeds[NSEEDS] = {
    0x243f6a8885a308d3ULL,
    0x13198a2e03707344ULL,
    0xa4093822299f31d0ULL,
    0x082efa98ec4e6c89ULL,
    0x452821e638d01377ULL,
    0xbe5466cf34e90c6cULL,
    0xc0ac29b7c97c50ddULL,
    0x3f84d5b5b5470917ULL
};

#define NCASES ((uint32_t)(sizeof(kCfgs) / sizeof(kCfgs[0])))
#define NTESTS (NCASES * NSEEDS)

static uint32_t in[NSAMPLES];
static volatile uint64_t sink;

static inline uint64_t rdcycle64(void)
{
    uint64_t v;
    __asm__ __volatile__("rdcycle %0" : "=r"(v));
    return v;
}

static inline uint64_t mix(uint64_t s, uint8_t b)
{
    return (s * 1315423911ULL) ^ (uint64_t)b;
}

static inline uint64_t lcg_next(uint64_t s)
{
    return s * 6364136223846793005ULL + 1442695040888963407ULL;
}

/* custom-3 (0x7b), matches cvxif_cfar1d pkg */
static inline void cfar_hw_reset(void)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 0, x0, x0, x0" ::: "memory");
}
static inline void cfar_hw_set_alpha(uint64_t a)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 4, x0, %0, x0" : : "r"(a) : "memory");
}
static inline void cfar_hw_set_training(uint64_t l, uint64_t r)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 8, x0, %0, %1" : : "r"(l), "r"(r) : "memory");
}
static inline void cfar_hw_set_guard(uint64_t l, uint64_t r)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 12, x0, %0, %1" : : "r"(l), "r"(r) : "memory");
}
static inline uint8_t cfar_hw_run(uint64_t x)
{
    uint64_t rd;
    __asm__ __volatile__(".insn r 0x7b, 1, 16, %0, %1, x0" : "=r"(rd) : "r"(x) : "memory");
    return (uint8_t)(rd & 0xffu);
}

static void init_input(uint64_t seed, uint32_t pattern)
{
    uint64_t s = seed;
    uint32_t i;
    for (i = 0; i < NSAMPLES; ++i) {
        s = lcg_next(s);
        switch (pattern & 3u) {
        case 0u:
            in[i] = (uint32_t)((s >> 16) & 0x3ffu);
            break;
        case 1u:
            in[i] = (uint32_t)((i * 37u + (i >> 2) * 13u + (uint32_t)(seed & 0x3ffu)) & 0x3ffu);
            break;
        case 2u: {
            uint32_t v = (uint32_t)((s >> 20) & 0x1ffu);
            if ((i & 31u) == 0u) v = 1023u;
            if ((i & 127u) == 63u) v = 0u;
            in[i] = v;
            break;
        }
        default:
            in[i] = (i & 1u) ? 1023u : 0u;
            break;
        }
    }
}

static uint32_t cfg_window_size(const cfar_cfg_t *cfg)
{
    return cfg->tl + cfg->tr + cfg->gl + cfg->gr + 1u;
}

static uint8_t cfar_sw_step(uint32_t w[MAXW], uint32_t *wcnt, uint8_t *det, uint32_t x,
                            const cfar_cfg_t *cfg)
{
    uint32_t i;
    uint32_t wsize = cfg_window_size(cfg);
    uint32_t cut = cfg->tr + cfg->gr;

    for (i = MAXW - 1u; i > 0u; --i) w[i] = w[i - 1u];
    w[0] = x;

    if ((*wcnt + 1u) < wsize) {
        *wcnt += 1u;
        return *det;
    }

    {
        uint64_t acc = 0u;
        uint32_t left_begin = cfg->tr + cfg->gr + 1u + cfg->gl;
        uint32_t left_end = left_begin + cfg->tl;
        uint32_t ttotal = cfg->tl + cfg->tr;
        uint64_t avg = 0u;
        uint64_t thr;

        for (i = 0; i < MAXW; ++i) {
            if ((i < cfg->tr) || ((i >= left_begin) && (i < left_end))) acc += w[i];
        }
        if (ttotal != 0u) avg = acc / ttotal;
        thr = avg * (uint64_t)cfg->alpha;
        *det = ((uint64_t)w[cut] > thr) ? 1u : 0u;
    }

    return *det;
}

static uint64_t run_sw(const cfar_cfg_t *cfg)
{
    uint64_t sum = 0u;
    uint32_t rep, i;
    uint32_t w[MAXW];
    for (rep = 0; rep < NREPS; ++rep) {
        uint32_t wcnt = 0u;
        uint8_t det = 0u;
        for (i = 0; i < MAXW; ++i) w[i] = 0u;
        for (i = 0; i < NSAMPLES; ++i) sum = mix(sum, cfar_sw_step(w, &wcnt, &det, in[i], cfg));
    }
    return sum;
}

static uint64_t run_hw(const cfar_cfg_t *cfg)
{
    uint64_t sum = 0u;
    uint32_t rep, i;
    cfar_hw_set_alpha(cfg->alpha);
    cfar_hw_set_training(cfg->tl, cfg->tr);
    cfar_hw_set_guard(cfg->gl, cfg->gr);
    for (rep = 0; rep < NREPS; ++rep) {
        cfar_hw_reset();
        for (i = 0; i < NSAMPLES; ++i) sum = mix(sum, cfar_hw_run(in[i]));
    }
    return sum;
}

int main(void)
{
    uint64_t t0, t1, sw_cyc, hw_cyc, sw_sum, hw_sum;
    uint64_t total_sw_cyc = 0u, total_hw_cyc = 0u, total_ops = 0u, total_sum = 0u;
    uint32_t c, s;
    uint32_t test_id = 0u;

    printf("CFAR CVXIF FPGA sign-off test (%u samples, %u reps, %u cfgs, %u seeds, %u tests)\n",
           NSAMPLES, NREPS, NCASES, NSEEDS, NTESTS);

    for (c = 0; c < NCASES; ++c) {
        uint32_t wsize_chk = cfg_window_size(&kCfgs[c]);
        if (wsize_chk > MAXW) {
            printf("FAIL: invalid cfg \"%s\" window=%u > MAXW=%u\n", kCfgs[c].name, wsize_chk, MAXW);
            return 1;
        }
    }

    for (c = 0; c < NCASES; ++c) {
        const cfar_cfg_t *cfg = &kCfgs[c];
        for (s = 0; s < NSEEDS; ++s) {
            uint64_t seed = kSeeds[s] ^ (0x9e3779b97f4a7c15ULL * (uint64_t)(c + 1u));
            uint32_t pattern = (c + s) & 3u;
            uint64_t ops = (uint64_t)NSAMPLES * (uint64_t)NREPS;
            uint32_t wsize = cfg_window_size(cfg);

            test_id += 1u;
            init_input(seed, pattern);
            printf("test %u/%u cfg=%u/%u \"%s\" alpha=%u tl=%u tr=%u gl=%u gr=%u win=%u pattern=%u seed[%u]=0x%016" PRIx64 "\n",
                   test_id, NTESTS, c + 1u, NCASES, cfg->name, cfg->alpha, cfg->tl, cfg->tr,
                   cfg->gl, cfg->gr, wsize, pattern, s, seed);

            t0 = rdcycle64();
            sw_sum = run_sw(cfg);
            t1 = rdcycle64();
            sw_cyc = t1 - t0;

            t0 = rdcycle64();
            hw_sum = run_hw(cfg);
            t1 = rdcycle64();
            hw_cyc = t1 - t0;

            total_sw_cyc += sw_cyc;
            total_hw_cyc += hw_cyc;
            total_ops += ops;
            total_sum ^= sw_sum;

            printf("  SW checksum: 0x%016" PRIx64 "\n", sw_sum);
            printf("  HW checksum: 0x%016" PRIx64 "\n", hw_sum);
            printf("  SW cycles : %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
                   sw_cyc, sw_cyc / ops, ((sw_cyc % ops) * 1000ULL) / ops);
            printf("  HW cycles : %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
                   hw_cyc, hw_cyc / ops, ((hw_cyc % ops) * 1000ULL) / ops);
            if (hw_cyc != 0u) {
                uint64_t sp = (sw_cyc * 1000ULL) / hw_cyc;
                printf("  Speedup HW/SW: %" PRIu64 ".%03" PRIu64 "x\n", sp / 1000ULL, sp % 1000ULL);
            }

            if (sw_sum != hw_sum) {
                printf("FAIL: mismatch HW vs SW at test %u (cfg=%s, seed_idx=%u)\n",
                       test_id, cfg->name, s);
                return 1;
            }
        }
    }

    sink = total_sum ^ total_sw_cyc ^ total_hw_cyc;
    printf("Aggregate ops: %" PRIu64 "\n", total_ops);
    printf("Aggregate SW cycles: %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
           total_sw_cyc, total_sw_cyc / total_ops, ((total_sw_cyc % total_ops) * 1000ULL) / total_ops);
    printf("Aggregate HW cycles: %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
           total_hw_cyc, total_hw_cyc / total_ops, ((total_hw_cyc % total_ops) * 1000ULL) / total_ops);
    if (total_hw_cyc != 0u) {
        uint64_t sp_total = (total_sw_cyc * 1000ULL) / total_hw_cyc;
        printf("Aggregate speedup HW/SW: %" PRIu64 ".%03" PRIu64 "x\n",
               sp_total / 1000ULL, sp_total % 1000ULL);
    }

    printf("PASS (all %u tests)\n", NTESTS);
    return 0;
}
