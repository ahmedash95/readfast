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
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
}

// Row-ending newlines in one 64-byte block. `carry` is all ones when the
// previous block ended inside quotes; it's updated for the next block.
static inline uint64_t newline_mask(const uint8_t *b, uint64_t *carry) {
    uint64_t inside = rf_prefix_xor(rf_eq_mask(b, '"')) ^ *carry;
    *carry = 0 - (inside >> 63);
    return rf_eq_mask(b, '\n') & ~inside;
}

size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c) {
    size_t count = 0, i = 0;
    for (; i + 64 <= n; i += 64) count += (size_t)__builtin_popcountll(rf_eq_mask(p + i, c));
    for (; i < n; i++) count += p[i] == c;
    return count;
}

static size_t count_newlines(const uint8_t *p, size_t n, uint64_t *carry) {
    size_t count = 0, i = 0;
    for (; i + 64 <= n; i += 64) count += (size_t)__builtin_popcountll(newline_mask(p + i, carry));
    if (i < n) {
        uint8_t pad[64] = {0}; // zeros are neither '"' nor '\n'
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(newline_mask(pad, carry));
    }
    return count;
}

int64_t rf_find_newline(const uint8_t *p, size_t n, bool inside, uint64_t k) {
    if (k == 0) return -1;
    uint64_t carry = inside ? ~0ULL : 0;
    for (size_t i = 0; i < n; i += 64) {
        uint8_t pad[64] = {0};
        const uint8_t *b = p + i;
        if (n - i < 64) { memcpy(pad, b, n - i); b = pad; }
        uint64_t m = newline_mask(b, &carry);
        uint64_t c = (uint64_t)__builtin_popcountll(m);
        if (c < k) { k -= c; continue; }
        while (--k) m &= m - 1; // drop the lower newlines
        return (int64_t)(i + (size_t)__builtin_ctzll(m));
    }
    return -1;
}

// ── Parallel index ───────────────────────────────────────────────────────────
// Pass 1: each chunk counts its quotes. Serial: chunk k starts inside quotes
// when chunks 0..k-1 hold an odd number of them. Pass 2: each chunk scans
// its blocks with the right starting state. Chunks are whole blocks, so every
// block is owned by exactly one thread.

#define RF_MAX_THREADS 256

typedef struct {
    const uint8_t *p;
    size_t n, bs, blocks, threads;
    uint32_t *counts;
    uint8_t *inside_at;
    size_t quotes[RF_MAX_THREADS];
    bool starts_inside[RF_MAX_THREADS];
    uint64_t ends[RF_MAX_THREADS];
} index_ctx;

static size_t chunk_first_block(const index_ctx *c, size_t k) { return c->blocks * k / c->threads; }

static void count_quotes_worker(void *ctx, size_t k) {
    index_ctx *c = ctx;
    size_t start = chunk_first_block(c, k) * c->bs;
    size_t end = chunk_first_block(c, k + 1) * c->bs;
    if (end > c->n) end = c->n;
    c->quotes[k] = rf_count_byte(c->p + start, end - start, '"');
}

static void scan_worker(void *ctx, size_t k) {
    index_ctx *c = ctx;
    uint64_t carry = c->starts_inside[k] ? ~0ULL : 0;
    for (size_t b = chunk_first_block(c, k); b < chunk_first_block(c, k + 1); b++) {
        size_t start = b * c->bs;
        size_t len = c->n - start < c->bs ? c->n - start : c->bs;
        c->inside_at[b] = carry != 0;
        c->counts[b] = (uint32_t)count_newlines(c->p + start, len, &carry);
    }
    c->ends[k] = carry;
}

bool rf_index(const uint8_t *p, size_t n, size_t bs, size_t threads, bool start_inside,
              uint32_t *counts, uint8_t *inside_at) {
    if (n == 0) return start_inside;
    size_t blocks = (n + bs - 1) / bs;
    if (threads < 1) threads = 1;
    if (threads > RF_MAX_THREADS) threads = RF_MAX_THREADS;
    if (threads > blocks) threads = blocks;

    index_ctx c = {.p = p, .n = n, .bs = bs, .blocks = blocks, .threads = threads,
                   .counts = counts, .inside_at = inside_at};
    if (threads > 1) dispatch_apply_f(threads, DISPATCH_APPLY_AUTO, &c, count_quotes_worker);
    size_t before = start_inside ? 1 : 0;
    for (size_t k = 0; k < threads; k++) {
        c.starts_inside[k] = before % 2 == 1;
        if (threads > 1) before += c.quotes[k];
    }
    dispatch_apply_f(threads, DISPATCH_APPLY_AUTO, &c, scan_worker);
    return c.ends[threads - 1] != 0;
}
