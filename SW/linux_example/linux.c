// Copyright (c) 2011-2025 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0

#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef uint32_t cfar_fp32_t;

_Static_assert(sizeof(float) == sizeof(cfar_fp32_t),
               "CFAR requires a 32-bit IEEE-754 float type");

static inline cfar_fp32_t cfar_f32_bits(float value)
{
    union { float f; uint32_t u; } cvt;
    cvt.f = value;
    return cvt.u;
}

static inline cfar_fp32_t cfar_fp32_negate(cfar_fp32_t value)
{
    return ((value & UINT32_C(0x7fffffff)) == 0u) ? 0u :
           (value ^ UINT32_C(0x80000000));
}

/* Bit-accurate model of HW/cfar1d/fp_mul32_lite.sv. */
static inline cfar_fp32_t cfar_fp32_mul_lite(cfar_fp32_t a, cfar_fp32_t b)
{
    uint32_t sres = (a ^ b) >> 31;
    uint32_t ea = (a >> 23) & 0xffu;
    uint32_t eb = (b >> 23) & 0xffu;
    uint32_t a_zero = (ea == 0u);
    uint32_t b_zero = (eb == 0u);
    uint32_t a_special = (ea == 0xffu);
    uint32_t b_special = (eb == 0xffu);
    uint32_t ma, mb, mres;
    uint64_t product, normalised;
    int32_t eres;

    if (a_special || b_special) {
        if (a_zero || b_zero) return 0u;
        return (sres << 31) | UINT32_C(0x7f7fffff);
    }
    if (a_zero || b_zero) return 0u;
    ma = UINT32_C(0x800000) | (a & UINT32_C(0x7fffff));
    mb = UINT32_C(0x800000) | (b & UINT32_C(0x7fffff));
    product = (uint64_t)ma * (uint64_t)mb;
    eres = (int32_t)ea + (int32_t)eb - 127;
    if ((product & (UINT64_C(1) << 47)) != 0u) {
        normalised = product >> 1;
        ++eres;
    } else {
        normalised = product;
    }
    mres = (uint32_t)((normalised >> 23) & UINT64_C(0xffffff));
    if ((eres <= 0) || (mres == 0u)) return 0u;
    if (eres >= 255) return (sres << 31) | UINT32_C(0x7f7fffff);
    return (sres << 31) | ((uint32_t)eres << 23) | (mres & UINT32_C(0x7fffff));
}

/* Bit-accurate model of HW/cfar1d/fp_addsub32_lite.sv. */
static inline cfar_fp32_t cfar_fp32_addsub_lite(
    cfar_fp32_t a, cfar_fp32_t b, uint32_t subtract)
{
    uint32_t sa = a >> 31;
    uint32_t sb = b >> 31;
    uint32_t sbe = sb ^ (subtract & 1u);
    uint32_t ea = (a >> 23) & 0xffu;
    uint32_t eb = (b >> 23) & 0xffu;
    uint32_t a_zero = (ea == 0u);
    uint32_t b_zero = (eb == 0u);
    uint32_t a_special = (ea == 0xffu);
    uint32_t b_special = (eb == 0xffu);
    uint32_t ma = a_zero ? 0u : (UINT32_C(0x800000) | (a & UINT32_C(0x7fffff)));
    uint32_t mb = b_zero ? 0u : (UINT32_C(0x800000) | (b & UINT32_C(0x7fffff)));
    uint32_t eae = a_zero ? 1u : ea;
    uint32_t ebe = b_zero ? 1u : eb;
    uint32_t swap = (eae < ebe) || ((eae == ebe) && (ma < mb));
    uint32_t el = swap ? ebe : eae;
    uint32_t es = swap ? eae : ebe;
    uint32_t ml = swap ? mb : ma;
    uint32_t ms = swap ? ma : mb;
    uint32_t sbig = swap ? sbe : sa;
    uint32_t ssmall = swap ? sa : sbe;
    uint32_t same_sign = (sbig == ssmall);
    uint32_t sres = sbig;
    uint32_t ediff = el - es;
    uint32_t msa = (ediff >= 24u) ? 0u : (ms >> ediff);
    uint32_t sum = same_sign ? (ml + msa) : (ml - msa);
    uint32_t mres;
    int32_t eres;

    if (a_special || b_special) {
        if (a_special && b_special && (sa != sbe)) return 0u;
        sres = a_special ? sa : sbe;
        return (sres << 31) | UINT32_C(0x7f7fffff);
    }
    if (same_sign && ((sum & UINT32_C(0x1000000)) != 0u)) {
        mres = sum >> 1;
        eres = (int32_t)el + 1;
    } else if ((sum & UINT32_C(0xffffff)) == 0u) {
        return 0u;
    } else if (same_sign) {
        mres = sum & UINT32_C(0xffffff);
        eres = (int32_t)el;
    } else {
        uint32_t lz = 0u;
        uint32_t bit = UINT32_C(0x800000);
        while ((sum & bit) == 0u) {
            ++lz;
            bit >>= 1;
        }
        mres = (sum << lz) & UINT32_C(0xffffff);
        eres = (int32_t)el - (int32_t)lz;
    }
    if ((eres <= 0) || (mres == 0u)) return 0u;
    if (eres >= 255) return (sres << 31) | UINT32_C(0x7f7fffff);
    return (sres << 31) | ((uint32_t)eres << 23) | (mres & UINT32_C(0x7fffff));
}

static inline int cfar_fp32_gt(cfar_fp32_t a, cfar_fp32_t b)
{
    uint32_t a_zero = ((a & UINT32_C(0x7fffffff)) == 0u);
    uint32_t b_zero = ((b & UINT32_C(0x7fffffff)) == 0u);
    if (a_zero && b_zero) return 0;
    if ((a >> 31) != (b >> 31)) return (int)(b >> 31);
    if ((a >> 31) == 0u)
        return (a & UINT32_C(0x7fffffff)) > (b & UINT32_C(0x7fffffff));
    return (a & UINT32_C(0x7fffffff)) < (b & UINT32_C(0x7fffffff));
}

static inline cfar_fp32_t cfar_complex_power_lite(float re, float im)
{
    cfar_fp32_t re_bits = cfar_f32_bits(re);
    cfar_fp32_t im_bits = cfar_f32_bits(im);
    cfar_fp32_t rr = cfar_fp32_mul_lite(re_bits, re_bits);
    cfar_fp32_t ii = cfar_fp32_mul_lite(im_bits, cfar_fp32_negate(im_bits));
    return cfar_fp32_addsub_lite(rr, ii, 1u);
}

static inline cfar_fp32_t cfar_tree_sum_lite(cfar_fp32_t values[], uint32_t count)
{
    uint32_t inputs = count;
    while (inputs > 1u) {
        uint32_t outputs = (inputs + 1u) / 2u;
        uint32_t i;
        for (i = 0u; i < outputs; ++i) {
            uint32_t first = 2u * i;
            values[i] = (first + 1u < inputs) ?
                        cfar_fp32_addsub_lite(values[first], values[first + 1u], 0u) :
                        values[first];
        }
        inputs = outputs;
    }
    return values[0];
}

#define NSAMPLES 4096u
#define NREPS      16u
#define MAXW      64u
#define NSEEDS      8u

typedef struct {
    float alpha;
    uint32_t tl;
    uint32_t tr;
    uint32_t gl;
    uint32_t gr;
    const char *name;
} cfar_cfg_t;

typedef struct {
    float re;
    float im;
} cfar_sample_t;

static const cfar_cfg_t kCfgs[] = {
    {3.0f, 4u, 4u, 1u, 1u, "base"},
    {2.3f, 6u, 6u, 1u, 1u, "wide_train_fractional_alpha"},
    {4.0f, 8u, 8u, 2u, 2u, "wide_guard_high_alpha"},
    {5.5f, 10u, 6u, 2u, 1u, "asymmetric_high_alpha"},
    {1.0f, 12u, 12u, 3u, 3u, "very_permissive"},
    {6.0f, 5u, 15u, 1u, 2u, "asymmetric_strict"},
    {0.0f, 0u, 0u, 0u, 0u, "min_window_alpha0"},
    {7.0f, 0u, 0u, 0u, 0u, "min_window_alpha7"},
    {3.0f, 30u, 30u, 1u, 2u, "max_window_balanced"},
    {2.0f, 31u, 28u, 2u, 2u, "max_window_asymmetric"},
    {3.0f, 2u, 2u, 20u, 20u, "wide_guard_small_train"},
    {4.0f, 20u, 20u, 0u, 0u, "high_train_no_guard"},
    {3.0f, 0u, 16u, 1u, 1u, "right_train_only"},
    {3.0f, 16u, 0u, 1u, 1u, "left_train_only"}
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

static cfar_sample_t in[NSAMPLES];
static volatile uint64_t sink;
static sigjmp_buf sigill_env;

typedef enum {
    TIMER_CYCLE = 0,
    TIMER_NS = 1
} timer_mode_t;

static timer_mode_t timer_mode = TIMER_CYCLE;

static inline uint64_t rdcycle64(void)
{
    uint64_t v;
    __asm__ __volatile__("rdcycle %0" : "=r"(v));
    return v;
}

static inline uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline uint64_t now_ticks(void)
{
    return (timer_mode == TIMER_CYCLE) ? rdcycle64() : now_ns();
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
static inline uint8_t cfar_hw_run(float re, float im)
{
    uint64_t rd;
    uint64_t re_bits = (uint64_t)cfar_f32_bits(re);
    uint64_t im_bits = (uint64_t)cfar_f32_bits(im);
    __asm__ __volatile__(".insn r 0x7b, 1, 16, %0, %1, %2"
                         : "=r"(rd)
                         : "r"(re_bits), "r"(im_bits)
                         : "memory");
    return (uint8_t)(rd & 0xffu);
}

static inline int32_t signed_10b(uint32_t v)
{
    return (int32_t)(v & 0x3ffu) - 512;
}

static void sigill_handler(int signo)
{
    (void)signo;
    siglongjmp(sigill_env, 1);
}

static int probe_rdcycle_u_mode(void)
{
    struct sigaction sa, old_sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigill_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGILL, &sa, &old_sa) != 0) return -1;

    if (sigsetjmp(sigill_env, 1) != 0) {
        sigaction(SIGILL, &old_sa, NULL);
        return -1;
    }

    (void)rdcycle64();
    sigaction(SIGILL, &old_sa, NULL);
    return 0;
}

static int probe_cfar_custom_u_mode(void)
{
    struct sigaction sa, old_sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigill_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGILL, &sa, &old_sa) != 0) return -1;

    if (sigsetjmp(sigill_env, 1) != 0) {
        sigaction(SIGILL, &old_sa, NULL);
        return -1;
    }

    cfar_hw_reset();
    sigaction(SIGILL, &old_sa, NULL);
    return 0;
}

static void init_input(uint64_t seed, uint32_t pattern)
{
    uint64_t s = seed;
    uint32_t i;
    for (i = 0; i < NSAMPLES; ++i) {
        s = lcg_next(s);
        switch (pattern & 3u) {
        case 0u:
            in[i].re = (float)signed_10b((uint32_t)(s >> 16)) * (1.0f / 16.0f);
            in[i].im = (float)signed_10b((uint32_t)(s >> 32)) * (1.0f / 16.0f);
            break;
        case 1u:
            in[i].re = (float)signed_10b(i * 37u + (i >> 2) * 13u +
                                        (uint32_t)(seed & 0x3ffu)) * 0.125f;
            in[i].im = (float)signed_10b(i * 19u + (i >> 3) * 29u +
                                        (uint32_t)((seed >> 16) & 0x3ffu)) * 0.125f;
            break;
        case 2u: {
            float re = (float)signed_10b((uint32_t)(s >> 20)) * 0.25f;
            float im = (float)signed_10b((uint32_t)(s >> 36)) * 0.25f;
            if ((i & 31u) == 0u) {
                re = 255.75f;
                im = -255.75f;
            }
            if ((i & 127u) == 63u) {
                re = 0;
                im = 0;
            }
            in[i].re = re;
            in[i].im = im;
            break;
        }
        default:
            in[i].re = (i & 1u) ? 63.9375f : -63.9375f;
            in[i].im = (i & 2u) ? 31.9375f : -31.9375f;
            break;
        }
    }
}

static uint32_t cfg_window_size(const cfar_cfg_t *cfg)
{
    return cfg->tl + cfg->tr + cfg->gl + cfg->gr + 1u;
}

static cfar_fp32_t cfg_embedded_alpha(const cfar_cfg_t *cfg)
{
    uint32_t training_total = cfg->tl + cfg->tr;
    if (training_total == 0u) return 0u;
    return cfar_f32_bits(cfg->alpha / (float)training_total);
}

typedef struct {
    float power[MAXW];
    float training_sum;
    uint32_t head;
    uint32_t count;
} cfar_sw_state_t;

static inline uint32_t cfar_sw_ring_index(const cfar_sw_state_t *state,
                                          uint32_t window_size,
                                          uint32_t age)
{
    uint32_t index = state->head + age;
    return (index < window_size) ? index : index - window_size;
}

static inline float cfar_sw_power(cfar_sample_t x)
{
    return x.re * x.re + x.im * x.im;
}

/* Conventional CA-CFAR: circular window and O(1) sliding training sum. */
static uint8_t cfar_sw_step(cfar_sw_state_t *state,
                            cfar_sample_t x,
                            const cfar_cfg_t *cfg,
                            float alpha_over_n)
{
    const uint32_t window_size = cfg_window_size(cfg);
    const uint32_t cut = cfg->tr + cfg->gr;
    const uint32_t left_begin = cut + 1u + cfg->gl;
    const float new_power = cfar_sw_power(x);

    if (state->count == 0u) {
        state->head = 0u;
    } else {
        state->head = (state->head == 0u) ? window_size - 1u : state->head - 1u;
    }

    if (state->count < window_size) {
        state->power[state->head] = new_power;
        ++state->count;

        if (state->count < window_size) return 0u;

        state->training_sum = 0.0f;
        for (uint32_t i = 0u; i < cfg->tr; ++i)
            state->training_sum +=
                state->power[cfar_sw_ring_index(state, window_size, i)];
        for (uint32_t i = 0u; i < cfg->tl; ++i)
            state->training_sum +=
                state->power[cfar_sw_ring_index(state, window_size, left_begin + i)];
    } else {
        float next_sum = state->training_sum;

        if (cfg->tr != 0u) {
            const uint32_t leaving_right =
                cfar_sw_ring_index(state, window_size, cfg->tr);
            next_sum += new_power - state->power[leaving_right];
        }
        if (cfg->tl != 0u) {
            const uint32_t entering_left =
                cfar_sw_ring_index(state, window_size, left_begin);
            const uint32_t leaving_left = state->head;
            next_sum += state->power[entering_left] - state->power[leaving_left];
        }

        state->power[state->head] = new_power;
        state->training_sum = next_sum;
    }

    return state->power[cfar_sw_ring_index(state, window_size, cut)] >
           state->training_sum * alpha_over_n;
}

static uint64_t run_sw(const cfar_cfg_t *cfg)
{
    uint64_t sum = 0u;
    uint32_t rep, i;
    const uint32_t training_total = cfg->tl + cfg->tr;
    const float alpha_over_n = (training_total == 0u) ? 0.0f :
                               cfg->alpha / (float)training_total;

    for (rep = 0; rep < NREPS; ++rep) {
        cfar_sw_state_t state = {0};
        for (i = 0; i < NSAMPLES; ++i)
            sum = mix(sum, cfar_sw_step(&state, in[i], cfg, alpha_over_n));
    }
    return sum;
}

static uint64_t run_hw(const cfar_cfg_t *cfg)
{
    uint64_t sum = 0u;
    uint32_t rep, i;
    cfar_fp32_t embedded_alpha = cfg_embedded_alpha(cfg);
    cfar_hw_set_alpha(embedded_alpha);
    cfar_hw_set_training(cfg->tl, cfg->tr);
    cfar_hw_set_guard(cfg->gl, cfg->gr);
    for (rep = 0; rep < NREPS; ++rep) {
        cfar_hw_reset();
        for (i = 0; i < NSAMPLES; ++i) sum = mix(sum, cfar_hw_run(in[i].re, in[i].im));
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

    if (probe_cfar_custom_u_mode() != 0) {
        printf("FAIL: CFAR custom instructions not available in Linux user mode\n");
        return 2;
    }

    if (probe_rdcycle_u_mode() != 0) {
        timer_mode = TIMER_NS;
        printf("NOTE: rdcycle is not accessible in Linux user mode, using CLOCK_MONOTONIC(ns)\n");
    }

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
            printf("test %u/%u cfg=%u/%u \"%s\" alpha_bits=0x%08" PRIx32
                   " alpha_over_n_bits=0x%08" PRIx32 " tl=%u tr=%u gl=%u gr=%u win=%u pattern=%u seed[%u]=0x%016" PRIx64 "\n",
                   test_id, NTESTS, c + 1u, NCASES, cfg->name,
                   cfar_f32_bits(cfg->alpha), cfg_embedded_alpha(cfg), cfg->tl, cfg->tr,
                   cfg->gl, cfg->gr, wsize, pattern, s, seed);

            t0 = now_ticks();
            sw_sum = run_sw(cfg);
            t1 = now_ticks();
            sw_cyc = t1 - t0;

            t0 = now_ticks();
            hw_sum = run_hw(cfg);
            t1 = now_ticks();
            hw_cyc = t1 - t0;

            total_sw_cyc += sw_cyc;
            total_hw_cyc += hw_cyc;
            total_ops += ops;
            total_sum ^= sw_sum;

            printf("  SW checksum: 0x%016" PRIx64 "\n", sw_sum);
            printf("  HW checksum: 0x%016" PRIx64 "\n", hw_sum);
            if (timer_mode == TIMER_CYCLE) {
                printf("  SW cycles : %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
                       sw_cyc, sw_cyc / ops, ((sw_cyc % ops) * (uint64_t)1000u) / ops);
                printf("  HW cycles : %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
                       hw_cyc, hw_cyc / ops, ((hw_cyc % ops) * (uint64_t)1000u) / ops);
            } else {
                printf("  SW time   : %" PRIu64 " ns (%" PRIu64 ".%03" PRIu64 " ns/op)\n",
                       sw_cyc, sw_cyc / ops, ((sw_cyc % ops) * (uint64_t)1000u) / ops);
                printf("  HW time   : %" PRIu64 " ns (%" PRIu64 ".%03" PRIu64 " ns/op)\n",
                       hw_cyc, hw_cyc / ops, ((hw_cyc % ops) * (uint64_t)1000u) / ops);
            }
            if (hw_cyc != 0u) {
                uint64_t sp = (sw_cyc * (uint64_t)1000u) / hw_cyc;
                printf("  Speedup HW/SW: %" PRIu64 ".%03" PRIu64 "x\n",
                       sp / (uint64_t)1000u, sp % (uint64_t)1000u);
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
    if (timer_mode == TIMER_CYCLE) {
        printf("Aggregate SW cycles: %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
               total_sw_cyc, total_sw_cyc / total_ops,
               ((total_sw_cyc % total_ops) * (uint64_t)1000u) / total_ops);
        printf("Aggregate HW cycles: %" PRIu64 " (%" PRIu64 ".%03" PRIu64 " cyc/op)\n",
               total_hw_cyc, total_hw_cyc / total_ops,
               ((total_hw_cyc % total_ops) * (uint64_t)1000u) / total_ops);
    } else {
        printf("Aggregate SW time: %" PRIu64 " ns (%" PRIu64 ".%03" PRIu64 " ns/op)\n",
               total_sw_cyc, total_sw_cyc / total_ops,
               ((total_sw_cyc % total_ops) * (uint64_t)1000u) / total_ops);
        printf("Aggregate HW time: %" PRIu64 " ns (%" PRIu64 ".%03" PRIu64 " ns/op)\n",
               total_hw_cyc, total_hw_cyc / total_ops,
               ((total_hw_cyc % total_ops) * (uint64_t)1000u) / total_ops);
    }
    if (total_hw_cyc != 0u) {
        uint64_t sp_total = (total_sw_cyc * (uint64_t)1000u) / total_hw_cyc;
        printf("Aggregate speedup HW/SW: %" PRIu64 ".%03" PRIu64 "x\n",
               sp_total / (uint64_t)1000u, sp_total % (uint64_t)1000u);
    }

    printf("PASS (all %u tests)\n", NTESTS);
    return 0;
}
