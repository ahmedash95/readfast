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

uint64_t rf_eq_mask16(const uint8_t *b, uint16_t c) {
#if defined(__ARM_NEON)
    // Same fold as rf_eq_mask after narrowing each u16 compare result to a byte.
    const uint8x16_t w = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
    const uint16x8_t v = vdupq_n_u16(c);
#define EQ16(k) vmovn_u16(vceqq_u16(vreinterpretq_u16_u8(vld1q_u8(b + 16 * (k))), v))
    uint8x16_t m0 = vandq_u8(vcombine_u8(EQ16(0), EQ16(1)), w);
    uint8x16_t m1 = vandq_u8(vcombine_u8(EQ16(2), EQ16(3)), w);
    uint8x16_t m2 = vandq_u8(vcombine_u8(EQ16(4), EQ16(5)), w);
    uint8x16_t m3 = vandq_u8(vcombine_u8(EQ16(6), EQ16(7)), w);
#undef EQ16
    uint8x16_t s = vpaddq_u8(vpaddq_u8(m0, m1), vpaddq_u8(m2, m3));
    s = vpaddq_u8(s, s);
    return vgetq_lane_u64(vreinterpretq_u64_u8(s), 0);
#else
    uint64_t m = 0;
    for (int i = 0; i < 64; i++) m |= (uint64_t)((uint16_t)(b[2 * i] | b[2 * i + 1] << 8) == c) << i;
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

// Every helper below takes the code unit; callers pass a constant RF_U8 on
// the UTF-8 path so it compiles to exactly the byte loop.
#define INLINE static inline __attribute__((always_inline))
#define STEP(u) ((u) == RF_U8 ? 64 : 128) // bytes per 64-unit mask

// Mask of one ASCII char. A u16 lane is read little-endian, so in big-endian
// data the ASCII byte is the high byte. '"' and '\n' never occur inside a
// surrogate pair, so unit compares are exact.
INLINE uint64_t eq(const uint8_t *b, rf_unit u, uint8_t c) {
    return u == RF_U8 ? rf_eq_mask(b, c) : rf_eq_mask16(b, u == RF_U16LE ? c : (uint16_t)(c << 8));
}

// Row-ending newlines in one 64-unit block. `carry` is all ones when the
// previous block ended inside quotes; it's updated for the next block.
INLINE uint64_t newline_mask(const uint8_t *b, uint64_t *carry, rf_unit u) {
    uint64_t inside = rf_prefix_xor(eq(b, u, '"')) ^ *carry;
    *carry = 0 - (inside >> 63);
    return eq(b, u, '\n') & ~inside;
}

INLINE size_t count_units(const uint8_t *p, size_t n, uint8_t c, rf_unit u) {
    size_t count = 0, i = 0;
    for (; i + STEP(u) <= n; i += STEP(u)) count += (size_t)__builtin_popcountll(eq(p + i, u, c));
    if (i < n) {
        uint8_t pad[128] = {0};
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(eq(pad, u, c));
    }
    return count;
}

size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c) { return count_units(p, n, c, RF_U8); }

INLINE size_t count_newlines(const uint8_t *p, size_t n, uint64_t *carry, rf_unit u) {
    size_t count = 0, i = 0;
    for (; i + STEP(u) <= n; i += STEP(u)) count += (size_t)__builtin_popcountll(newline_mask(p + i, carry, u));
    if (i < n) {
        uint8_t pad[128] = {0}; // zeros are neither '"' nor '\n'
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(newline_mask(pad, carry, u));
    }
    return count;
}

INLINE int64_t find_newline(const uint8_t *p, size_t n, bool inside, uint64_t k, rf_unit u) {
    if (k == 0) return -1;
    uint64_t carry = inside ? ~0ULL : 0;
    for (size_t i = 0; i < n; i += STEP(u)) {
        uint8_t pad[128] = {0};
        const uint8_t *b = p + i;
        if (n - i < STEP(u)) { memcpy(pad, b, n - i); b = pad; }
        uint64_t m = newline_mask(b, &carry, u);
        uint64_t c = (uint64_t)__builtin_popcountll(m);
        if (c < k) { k -= c; continue; }
        while (--k) m &= m - 1; // drop the lower newlines
        return (int64_t)(i + (size_t)__builtin_ctzll(m) * (u == RF_U8 ? 1 : 2));
    }
    return -1;
}

int64_t rf_find_newline_units(const uint8_t *p, size_t n, bool inside, uint64_t k, rf_unit u) {
    return u == RF_U8 ? find_newline(p, n, inside, k, RF_U8) : find_newline(p, n, inside, k, u);
}

int64_t rf_find_newline(const uint8_t *p, size_t n, bool inside, uint64_t k) {
    return find_newline(p, n, inside, k, RF_U8);
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
    rf_unit unit;
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
    c->quotes[k] = c->unit == RF_U8 ? count_units(c->p + start, end - start, '"', RF_U8)
                                    : count_units(c->p + start, end - start, '"', c->unit);
}

static void scan_worker(void *ctx, size_t k) {
    index_ctx *c = ctx;
    uint64_t carry = c->starts_inside[k] ? ~0ULL : 0;
    for (size_t b = chunk_first_block(c, k); b < chunk_first_block(c, k + 1); b++) {
        size_t start = b * c->bs;
        size_t len = c->n - start < c->bs ? c->n - start : c->bs;
        c->inside_at[b] = carry != 0;
        c->counts[b] = (uint32_t)(c->unit == RF_U8 ? count_newlines(c->p + start, len, &carry, RF_U8)
                                                    : count_newlines(c->p + start, len, &carry, c->unit));
    }
    c->ends[k] = carry;
}

bool rf_index(const uint8_t *p, size_t n, size_t bs, size_t threads, bool start_inside,
              uint32_t *counts, uint8_t *inside_at) {
    return rf_index_units(p, n, bs, threads, start_inside, counts, inside_at, RF_U8);
}

bool rf_index_units(const uint8_t *p, size_t n, size_t bs, size_t threads, bool start_inside,
                    uint32_t *counts, uint8_t *inside_at, rf_unit unit) {
    if (n == 0) return start_inside;
    size_t blocks = (n + bs - 1) / bs;
    if (threads < 1) threads = 1;
    if (threads > RF_MAX_THREADS) threads = RF_MAX_THREADS;
    if (threads > blocks) threads = blocks;

    index_ctx c = {.p = p, .n = n, .bs = bs, .blocks = blocks, .threads = threads,
                   .counts = counts, .inside_at = inside_at, .unit = unit};
    if (threads > 1) dispatch_apply_f(threads, DISPATCH_APPLY_AUTO, &c, count_quotes_worker);
    size_t before = start_inside ? 1 : 0;
    for (size_t k = 0; k < threads; k++) {
        c.starts_inside[k] = before % 2 == 1;
        if (threads > 1) before += c.quotes[k];
    }
    dispatch_apply_f(threads, DISPATCH_APPLY_AUTO, &c, scan_worker);
    return c.ends[threads - 1] != 0;
}

// ── Encoding detection ───────────────────────────────────────────────────────

void rf_count_zeros(const uint8_t *p, size_t n, size_t *even, size_t *odd) {
    size_t e = 0, o = 0, i = 0;
    for (; i + 64 <= n; i += 64) {
        uint64_t m = rf_eq_mask(p + i, 0);
        e += (size_t)__builtin_popcountll(m & 0x5555555555555555ULL);
        o += (size_t)__builtin_popcountll(m & 0xAAAAAAAAAAAAAAAAULL);
    }
    for (; i < n; i++) if (p[i] == 0) { if (i % 2) o++; else e++; }
    *even = e;
    *odd = o;
}

bool rf_utf8_valid(const uint8_t *p, size_t n, bool allow_cut) {
    size_t i = 0;
    while (i < n) {
#if defined(__ARM_NEON)
        while (i + 16 <= n && vmaxvq_u8(vld1q_u8(p + i)) < 0x80) i += 16; // skip ASCII runs
        if (i >= n) break;
#endif
        uint8_t c = p[i];
        if (c < 0x80) { i++; continue; }
        size_t len;
        uint8_t lo = 0x80, hi = 0xBF; // 2nd byte range: no overlongs, surrogates or > U+10FFFF
        if (c >= 0xC2 && c <= 0xDF) len = 2;
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; if (c == 0xE0) lo = 0xA0; if (c == 0xED) hi = 0x9F; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; if (c == 0xF0) lo = 0x90; if (c == 0xF4) hi = 0x8F; }
        else return false;
        for (size_t k = 1; k < len; k++) {
            if (i + k >= n) return allow_cut;
            uint8_t d = p[i + k];
            if (k == 1 ? (d < lo || d > hi) : (d & 0xC0) != 0x80) return false;
        }
        i += len;
    }
    return true;
}
