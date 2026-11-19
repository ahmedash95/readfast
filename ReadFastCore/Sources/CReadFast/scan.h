// The quote-rule block kernel (see readfast.h), shared by the row index and
// search. Private: static inline so both translation units get it inlined.
#pragma once
#include "readfast.h"

// Runs fn(ctx, 0..<n) on n threads and waits: libdispatch on Apple, pthreads
// elsewhere (Linux toolchains don't put dispatch.h on the C include path).
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
static inline void rf_parallel(size_t n, void *ctx, void (*fn)(void *, size_t)) {
    dispatch_apply_f(n, DISPATCH_APPLY_AUTO, ctx, fn);
}
#else
#include <pthread.h>
#include <stdlib.h>
typedef struct { void *ctx; void (*fn)(void *, size_t); size_t i; pthread_t id; bool started; } rf_job;
static void *rf_job_run(void *p) {
    rf_job *j = p;
    j->fn(j->ctx, j->i);
    return NULL;
}
static inline void rf_parallel(size_t n, void *ctx, void (*fn)(void *, size_t)) {
    rf_job *jobs = n > 1 ? calloc(n, sizeof(rf_job)) : NULL;
    for (size_t i = 1; i < n; i++) {
        jobs[i] = (rf_job){.ctx = ctx, .fn = fn, .i = i};
        jobs[i].started = pthread_create(&jobs[i].id, NULL, rf_job_run, &jobs[i]) == 0;
        if (!jobs[i].started) fn(ctx, i); // no thread available: run it here
    }
    if (n > 0) fn(ctx, 0);
    for (size_t i = 1; i < n; i++) if (jobs[i].started) pthread_join(jobs[i].id, NULL);
    free(jobs);
}
#endif
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#define RF_INLINE static inline __attribute__((always_inline))
#define RF_STEP(u) ((u) == RF_U8 ? 64 : 128) // bytes per 64-unit mask

typedef struct {
    uint8_t delim, nl;
} rf_syntax;

// Bit i = XOR of bits 0...i (rf_prefix_xor, inlined).
RF_INLINE uint64_t rf_pxor(uint64_t x) {
#if defined(__ARM_FEATURE_AES)
    // carry-less multiply by all ones: bit i = XOR of bits 0...i, in one instruction
    return (uint64_t)vmull_p64(x, ~0ULL);
#else
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
#endif
}

// The scan state as masks, so the block-to-block dependency stays a few ALU
// ops: `in` is all ones inside a quoted field, `un` is 1 in an unquoted one.
typedef struct {
    uint64_t in, un;
} rf_carry;

RF_INLINE rf_carry rf_to_carry(uint8_t state) {
    return (rf_carry){state == RF_QUOTED ? ~0ULL : 0, state == RF_UNQUOTED};
}

RF_INLINE uint8_t rf_from_carry(rf_carry c) { return c.in ? RF_QUOTED : c.un ? RF_UNQUOTED : RF_FIELD; }

// Unit i of a block as a number ('"' is 0x22 in every mode).
RF_INLINE uint16_t rf_unit_at(const uint8_t *b, size_t i, rf_unit u) {
    return u == RF_U8 ? b[i] : u == RF_U16LE ? (uint16_t)(b[2 * i] | b[2 * i + 1] << 8) : (uint16_t)(b[2 * i] << 8 | b[2 * i + 1]);
}

// Mask of one ASCII char over 64 units. A u16 lane is read little-endian, so
// in big-endian data the ASCII byte is the high byte. '"', delimiters and
// newlines never occur inside a surrogate pair, so unit compares are exact.
RF_INLINE uint64_t rf_eq_units(const uint8_t *b, rf_unit u, uint8_t c) {
    return u == RF_U8 ? rf_eq_mask(b, c) : rf_eq_mask16(b, u == RF_U16LE ? c : (uint16_t)(c << 8));
}

#if defined(__ARM_NEON)
// Bit i <=> byte i == c, for 64 bytes loaded with vld4q_u8 (lane j of val[k]
// is byte 4j + k). Fewer ops than rf_eq_mask's and + pairwise adds.
RF_INLINE uint64_t rf_movemask4(uint8x16x4_t x, uint8x16_t c) {
    uint8x16_t t0 = vsriq_n_u8(vceqq_u8(x.val[1], c), vceqq_u8(x.val[0], c), 1);
    uint8x16_t t1 = vsriq_n_u8(vceqq_u8(x.val[3], c), vceqq_u8(x.val[2], c), 1);
    uint8x16_t t2 = vsriq_n_u8(t1, t0, 2);
    uint8x16_t t3 = vsriq_n_u8(t2, t2, 4);
    return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(t3), 4)), 0);
}
#endif

// A run of quotes is either all structural (it starts at a field start or
// inside a quoted field: each quote toggles, so "" is an escape) or all plain
// (it starts after an ordinary unit outside quotes). The caller assumed every
// quote toggles and found a plain run: drop the first one and redo the prefix
// XOR until none is left. Only stray quotes get here, so it's out of line.
__attribute__((noinline, cold)) static uint64_t rf_drop_plain_runs(uint64_t q, uint64_t lone, uint64_t in0, uint64_t *t) {
    for (;;) {
        uint64_t inside = rf_pxor(*t) ^ in0;   // inside after unit i
        uint64_t plain = lone & *t & ~(inside ^ *t); // outside quotes before unit i
        if (!plain) return inside;
        uint64_t first = plain & (0 - plain);
        uint64_t from = q & ~(first - 1);
        *t &= ~(from & ~(from + first)); // the whole run starting at `first`
    }
}

// Row-ending newlines in one block of 64 units. *carry is the state before
// unit 0; it becomes the state after unit `last` (63 except for a padded
// tail). Optional outputs: `inside_out` = inside a quoted field after unit i,
// `close_out` = the quotes that close a quoted field.
RF_INLINE uint64_t rf_block(const uint8_t *b, rf_syntax s, rf_carry *carry, int last, rf_unit u,
                            uint64_t *inside_out, uint64_t *close_out) {
#if defined(__ARM_NEON)
    // vld4 deinterleaves: x.val[k] holds bytes k, k+4, k+8, ..., so eq4() can
    // pack the four compares into a natural-order mask with shift-inserts.
    uint8x16x4_t x;
    if (u == RF_U8) x = vld4q_u8(b);
#define EQ(c) (u == RF_U8 ? rf_movemask4(x, vdupq_n_u8(c)) : rf_eq_units(b, u, c))
#else
#define EQ(c) rf_eq_units(b, u, c)
#endif
    uint64_t q = EQ('"'), n = EQ(s.nl);
    uint64_t in0 = carry->in;
    uint64_t inside = in0, t = 0; // t: the quotes that toggle
    uint64_t ordinary;            // units after which an outside scan is RF_UNQUOTED
    if (q) {
        uint64_t special = q | n | EQ(s.delim);
        // quotes right after an ordinary unit: plain unless inside a quoted field
        uint64_t lone = (q & ~(special << 1 | 1)) | (q & carry->un);
        t = q;
        inside = rf_pxor(q) ^ in0;
        if (lone & ~(inside ^ q)) inside = rf_drop_plain_runs(q, lone, in0, &t);
        ordinary = ~special | (q & ~t);
    } else {
        uint16_t c = rf_unit_at(b, (size_t)last, u);
        ordinary = (uint64_t)(c != s.delim && c != s.nl) << last;
    }
#undef EQ
    uint64_t in = inside >> last & 1;
    carry->in = 0 - in;
    carry->un = ordinary >> last & 1 & ~in;
    if (inside_out) *inside_out = inside;
    if (close_out) *close_out = t & ~inside;
    return n & ~inside;
}
