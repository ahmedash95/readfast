#include "readfast.h"
#include <dispatch/dispatch.h>
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

uint64_t rf_eq_mask(const uint8_t *b, uint8_t c) {
#if defined(__ARM_NEON)
    // Compare 4x16 bytes, keep one weighted bit per lane, then three rounds
    // of pairwise adds fold 64 lanes into 8 bytes = one u64, lowest byte first.
    const uint8x16_t w = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
    const uint8x16_t v = vdupq_n_u8(c);
    uint8x16_t m0 = vandq_u8(vceqq_u8(vld1q_u8(b), v), w);
    uint8x16_t m1 = vandq_u8(vceqq_u8(vld1q_u8(b + 16), v), w);
    uint8x16_t m2 = vandq_u8(vceqq_u8(vld1q_u8(b + 32), v), w);
    uint8x16_t m3 = vandq_u8(vceqq_u8(vld1q_u8(b + 48), v), w);
    uint8x16_t s = vpaddq_u8(vpaddq_u8(m0, m1), vpaddq_u8(m2, m3));
    s = vpaddq_u8(s, s);
    return vgetq_lane_u64(vreinterpretq_u64_u8(s), 0);
#else
    // ponytail: scalar fallback for Intel Macs / x86 simulators; add SSE2 movemask if they matter.
    uint64_t m = 0;
    for (int i = 0; i < 64; i++) m |= (uint64_t)(b[i] == c) << i;
    return m;
#endif
}

uint64_t rf_prefix_xor(uint64_t x) {
#if defined(__ARM_FEATURE_AES)
    // carry-less multiply by all ones: bit i = XOR of bits 0...i, in one instruction
    return (uint64_t)vmull_p64(x, ~0ULL);
#endif
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
}

typedef struct {
    uint8_t delim, nl;
} rf_syntax;

#if defined(__ARM_NEON)
// Bit i <=> byte i == c, for 64 bytes loaded with vld4q_u8 (lane j of val[k]
// is byte 4j + k). Fewer ops than rf_eq_mask's and + pairwise adds.
static inline uint64_t movemask4(uint8x16x4_t x, uint8x16_t c) {
    uint8x16_t t0 = vsriq_n_u8(vceqq_u8(x.val[1], c), vceqq_u8(x.val[0], c), 1);
    uint8x16_t t1 = vsriq_n_u8(vceqq_u8(x.val[3], c), vceqq_u8(x.val[2], c), 1);
    uint8x16_t t2 = vsriq_n_u8(t1, t0, 2);
    uint8x16_t t3 = vsriq_n_u8(t2, t2, 4);
    return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(t3), 4)), 0);
}
#endif

// The scan state as masks, so the block-to-block dependency stays a few ALU
// ops: `in` is all ones inside a quoted field, `un` is 1 in an unquoted one.
typedef struct {
    uint64_t in, un;
} carry_t;

static inline carry_t to_carry(uint8_t state) {
    return (carry_t){state == RF_QUOTED ? ~0ULL : 0, state == RF_UNQUOTED};
}

static inline uint8_t from_carry(carry_t c) { return c.in ? RF_QUOTED : c.un ? RF_UNQUOTED : RF_FIELD; }

// A run of quotes is either all structural (it starts at a field start or
// inside a quoted field: each quote toggles, so "" is an escape) or all plain
// (it starts after an ordinary byte outside quotes). The caller assumed every
// quote toggles and found a plain run: drop the first one and redo the prefix
// XOR until none is left. Only stray quotes get here, so it's out of line.
__attribute__((noinline, cold)) static uint64_t drop_plain_runs(uint64_t q, uint64_t lone, uint64_t in0, uint64_t *t) {
    for (;;) {
        uint64_t inside = rf_prefix_xor(*t) ^ in0; // inside after byte i
        uint64_t plain = lone & *t & ~(inside ^ *t); // outside quotes before byte i
        if (!plain) return inside;
        uint64_t first = plain & (0 - plain);
        uint64_t from = q & ~(first - 1);
        *t &= ~(from & ~(from + first)); // the whole run starting at `first`
    }
}

// Row-ending newlines in one 64-byte block. *carry is the state before b[0];
// it becomes the state after b[last] (last = 63 except for a padded tail).
static inline uint64_t row_end_mask(const uint8_t *b, rf_syntax s, carry_t *carry, int last) {
#if defined(__ARM_NEON)
    // vld4 deinterleaves: x.val[k] holds bytes k, k+4, k+8, ..., so eq4() can
    // pack the four compares into a natural-order mask with shift-inserts.
    uint8x16x4_t x = vld4q_u8(b);
#define eq4(c) movemask4(x, vdupq_n_u8(c))
#else
#define eq4(c) rf_eq_mask(b, c)
#endif
    uint64_t q = eq4('"'), n = eq4(s.nl);
    uint64_t in0 = carry->in;
    uint64_t inside = in0, t = q; // t: the quotes that toggle
    uint64_t ordinary;            // bytes after which an outside scan is RF_UNQUOTED
    if (q) {
        uint64_t special = q | n | eq4(s.delim);
        // quotes right after an ordinary byte: plain unless inside a quoted field
        uint64_t lone = (q & ~(special << 1 | 1)) | (q & carry->un);
        inside = rf_prefix_xor(q) ^ in0;
        if (lone & ~(inside ^ q)) inside = drop_plain_runs(q, lone, in0, &t);
        ordinary = ~special | (q & ~t);
    } else {
        ordinary = (uint64_t)(b[last] != s.delim && b[last] != s.nl) << last;
    }
    uint64_t in = inside >> last & 1;
    carry->in = 0 - in;
    carry->un = ordinary >> last & 1 & ~in;
    return n & ~inside;
#undef eq4
}

size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c) {
    size_t count = 0, i = 0;
    for (; i + 64 <= n; i += 64) count += (size_t)__builtin_popcountll(rf_eq_mask(p + i, c));
    for (; i < n; i++) count += p[i] == c;
    return count;
}

static size_t count_newlines(const uint8_t *p, size_t n, rf_syntax s, uint8_t *state) {
    size_t count = 0, i = 0;
    carry_t st = to_carry(*state);
    for (; i + 64 <= n; i += 64) count += (size_t)__builtin_popcountll(row_end_mask(p + i, s, &st, 63));
    if (i < n) {
        uint8_t pad[64] = {0}; // zeros are neither '"' nor a newline
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(row_end_mask(pad, s, &st, (int)(n - i - 1)));
    }
    *state = from_carry(st);
    return count;
}

int64_t rf_find_newline(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k) {
    if (k == 0) return -1;
    rf_syntax s = {delim, nl};
    carry_t st = to_carry(state);
    size_t i = 0;
    uint64_t m = 0, c = 0;
    for (; i + 64 <= n; i += 64) {
        m = row_end_mask(p + i, s, &st, 63);
        c = (uint64_t)__builtin_popcountll(m);
        if (c >= k) goto found;
        k -= c;
    }
    if (i < n) {
        uint8_t pad[64] = {0};
        memcpy(pad, p + i, n - i);
        m = row_end_mask(pad, s, &st, (int)(n - i - 1));
        if ((uint64_t)__builtin_popcountll(m) >= k) goto found;
    }
    return -1;
found:
    while (--k) m &= m - 1; // drop the lower newlines
    return (int64_t)(i + (size_t)__builtin_ctzll(m));
}

// ── Parallel index ───────────────────────────────────────────────────────────
// The state at a chunk start depends on everything before it, so chunks
// speculate: each guesses its start state from the byte before it (inside a
// quoted field is the one thing it can't see) and scans its blocks. Then,
// serially, chunk k's real start is chunk k-1's end; on a wrong guess its
// blocks are rescanned until the state at a block start matches the guess's
// (from there on the results are the same). Normal files rescan nothing or
// one block per chunk; an unclosed quote rescans the rest at one-core speed.
// Chunks are whole blocks, so every block is owned by exactly one thread.

#define RF_MAX_THREADS 256

typedef struct {
    const uint8_t *p;
    size_t n, bs, blocks, threads;
    rf_syntax s;
    uint32_t *counts;
    uint8_t *state_at;
    uint8_t starts[RF_MAX_THREADS];
    uint8_t ends[RF_MAX_THREADS];
} index_ctx;

static size_t chunk_first_block(const index_ctx *c, size_t k) { return c->blocks * k / c->threads; }

static void scan_block(index_ctx *c, size_t b, uint8_t *state) {
    size_t start = b * c->bs;
    size_t len = c->n - start < c->bs ? c->n - start : c->bs;
    c->state_at[b] = *state;
    c->counts[b] = (uint32_t)count_newlines(c->p + start, len, c->s, state);
}

static void scan_worker(void *ctx, size_t k) {
    index_ctx *c = ctx;
    size_t first = chunk_first_block(c, k);
    uint8_t state = c->starts[k];
    if (k > 0) { // guess from the previous byte, assuming it's outside quotes
        uint8_t prev = c->p[first * c->bs - 1];
        state = prev == c->s.delim || prev == c->s.nl || prev == '"' ? RF_FIELD : RF_UNQUOTED;
    }
    for (size_t b = first; b < chunk_first_block(c, k + 1); b++) scan_block(c, b, &state);
    c->ends[k] = state;
}

uint8_t rf_index(const uint8_t *p, size_t n, size_t bs, size_t threads, uint8_t delim, uint8_t nl,
                 uint8_t start_state, uint32_t *counts, uint8_t *state_at) {
    if (n == 0) return start_state;
    size_t blocks = (n + bs - 1) / bs;
    if (threads < 1) threads = 1;
    if (threads > RF_MAX_THREADS) threads = RF_MAX_THREADS;
    if (threads > blocks) threads = blocks;

    index_ctx c = {.p = p, .n = n, .bs = bs, .blocks = blocks, .threads = threads, .s = {delim, nl},
                   .counts = counts, .state_at = state_at};
    c.starts[0] = start_state;
    dispatch_apply_f(threads, DISPATCH_APPLY_AUTO, &c, scan_worker);
    uint8_t state = c.ends[0];
    for (size_t k = 1; k < threads; k++) {
        size_t b = chunk_first_block(&c, k), end = chunk_first_block(&c, k + 1);
        while (b < end && state != state_at[b]) scan_block(&c, b++, &state);
        if (b < end) state = c.ends[k]; // converged: the guess's end holds
    }
    return state;
}
