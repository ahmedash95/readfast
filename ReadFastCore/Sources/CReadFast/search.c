#include "rf_search.h"
#include "readfast.h"
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// Bit i set <=> (b[i] | o) == c. With o = 0x20 and a lowercase letter c this
// matches both cases and nothing else. Reads exactly 64 bytes. Same trick as
// rf_eq_mask, inlined here because the scan calls it 5 times per block.
static inline uint64_t eq_or(const uint8_t *b, uint8_t c, uint8_t o) {
#if defined(__ARM_NEON)
    const uint8x16_t w = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
    const uint8x16_t v = vdupq_n_u8(c), ov = vdupq_n_u8(o);
    uint8x16_t m0 = vandq_u8(vceqq_u8(vorrq_u8(vld1q_u8(b), ov), v), w);
    uint8x16_t m1 = vandq_u8(vceqq_u8(vorrq_u8(vld1q_u8(b + 16), ov), v), w);
    uint8x16_t m2 = vandq_u8(vceqq_u8(vorrq_u8(vld1q_u8(b + 32), ov), v), w);
    uint8x16_t m3 = vandq_u8(vceqq_u8(vorrq_u8(vld1q_u8(b + 48), ov), v), w);
    uint8x16_t s = vpaddq_u8(vpaddq_u8(m0, m1), vpaddq_u8(m2, m3));
    s = vpaddq_u8(s, s);
    return vgetq_lane_u64(vreinterpretq_u64_u8(s), 0);
#else
    uint64_t m = 0;
    for (int i = 0; i < 64; i++) m |= (uint64_t)((b[i] | o) == c) << i;
    return m;
#endif
}

static inline uint64_t prefix_xor(uint64_t x) {
    x ^= x << 1; x ^= x << 2; x ^= x << 4; x ^= x << 8; x ^= x << 16; x ^= x << 32;
    return x;
}

static inline uint8_t lower(uint8_t c) { return c >= 'A' && c <= 'Z' ? c | 0x20 : c; }
static inline uint8_t fold_mask(uint8_t c) { return c >= 'a' && c <= 'z' ? 0x20 : 0; }
static inline int64_t last_bit(size_t i, uint64_t m) { return (int64_t)(i + 63 - (size_t)__builtin_clzll(m)); }

typedef struct {
    rf_hit *hits;
    size_t count, cap, quotes;
    bool inside, ends_inside;
    uint64_t newlines;
    int64_t last_nl, last_bound; // -1: none in this chunk
} chunk_t;

typedef struct {
    const uint8_t *p, *needle; // needle lowercased when folding
    size_t n, from, to, blocks, threads, len;
    bool fold;
    uint8_t delim, f, fo, l, lo; // first/last needle byte and their OR masks
    chunk_t *chunks;
} search_ctx;

static size_t chunk_start(const search_ctx *c, size_t k) {
    size_t s = c->from + c->blocks * k / c->threads * 64;
    return s < c->to ? s : c->to;
}

static bool verify(const search_ctx *c, size_t j) {
    if (!c->fold) return memcmp(c->p + j, c->needle, c->len) == 0;
    for (size_t k = 0; k < c->len; k++)
        if (lower(c->p[j + k]) != c->needle[k]) return false;
    return true;
}

// Positions in [i, i + 64) where the first and last needle bytes fit.
static inline uint64_t candidates(const search_ctx *c, size_t i) {
    if (i + 63 + c->len <= c->n) {
        uint64_t m = eq_or(c->p + i, c->f, c->fo);
        return c->len == 1 ? m : m & eq_or(c->p + i + c->len - 1, c->l, c->lo);
    }
    uint64_t m = 0; // near the end of the file: scalar, never reads past n
    for (size_t j = 0; j < 64 && i + j + c->len <= c->n; j++)
        m |= (uint64_t)((c->p[i + j] | c->fo) == c->f && (c->p[i + j + c->len - 1] | c->lo) == c->l) << j;
    return m;
}

static void push(chunk_t *ch, rf_hit h) {
    if (ch->count == ch->cap) {
        ch->cap = ch->cap ? ch->cap * 2 : 64;
        ch->hits = realloc(ch->hits, ch->cap * sizeof(rf_hit));
    }
    ch->hits[ch->count++] = h;
}

static void count_quotes(void *ctx, size_t k) {
    search_ctx *c = ctx;
    size_t s = chunk_start(c, k);
    c->chunks[k].quotes = rf_count_byte(c->p + s, chunk_start(c, k + 1) - s, '"');
}

// Hits hold chunk-local values: row = newlines before it in this chunk;
// cell / row_start = -1 when they begin before the chunk. rf_search fixes them up.
static void scan(void *ctx, size_t k) {
    search_ctx *c = ctx;
    chunk_t *ch = &c->chunks[k];
    size_t e = chunk_start(c, k + 1);
    uint64_t carry = ch->inside ? ~0ULL : 0, newlines = 0;
    int64_t last_nl = -1, last_bound = -1, last_cell = INT64_MIN;
    for (size_t i = chunk_start(c, k); i < e; i += 64) {
        size_t len = e - i < 64 ? e - i : 64;
        const uint8_t *b = c->p + i;
        uint8_t pad[64] = {0}; // zeros are neither '"', '\n' nor a delimiter
        if (len < 64) { memcpy(pad, b, len); b = pad; }
        uint64_t inside = prefix_xor(eq_or(b, '"', 0)) ^ carry;
        carry = 0 - (inside >> 63);
        uint64_t nl = eq_or(b, '\n', 0) & ~inside;
        uint64_t bound = nl | (eq_or(b, c->delim, 0) & ~inside);
        uint64_t cand = candidates(c, i) & (len < 64 ? (1ULL << len) - 1 : ~0ULL);
        while (cand) {
            size_t j = (size_t)__builtin_ctzll(cand);
            cand &= cand - 1;
            if (!verify(c, i + j)) continue;
            uint64_t below = (1ULL << j) - 1, bb = bound & below, nb = nl & below;
            int64_t cell = bb ? last_bit(i, bb) + 1 : last_bound >= 0 ? last_bound + 1 : -1;
            if (cell == last_cell) continue; // one hit per cell
            last_cell = cell;
            int64_t rs = nb ? last_bit(i, nb) + 1 : last_nl >= 0 ? last_nl + 1 : -1;
            push(ch, (rf_hit){cell, rs, newlines + (uint64_t)__builtin_popcountll(nb)});
        }
        newlines += (uint64_t)__builtin_popcountll(nl);
        if (nl) last_nl = last_bit(i, nl);
        if (bound) last_bound = last_bit(i, bound);
    }
    ch->newlines = newlines;
    ch->last_nl = last_nl;
    ch->last_bound = last_bound;
    ch->ends_inside = carry != 0;
}

size_t rf_search(const uint8_t *p, size_t n, size_t from, size_t to, const uint8_t *needle, size_t len,
                 bool fold, uint8_t delim, size_t threads, rf_search_state *st, rf_hit **out) {
    *out = NULL;
    if (from >= to || len == 0) return 0;
    uint8_t *lowered = NULL;
    if (fold) {
        lowered = malloc(len);
        for (size_t k = 0; k < len; k++) lowered[k] = lower(needle[k]);
        needle = lowered;
    }
    search_ctx c = {.p = p, .needle = needle, .n = n, .from = from, .to = to, .len = len, .fold = fold,
                    .delim = delim, .f = needle[0], .l = needle[len - 1]};
    if (fold) { c.fo = fold_mask(c.f); c.lo = fold_mask(c.l); }
    c.blocks = (to - from + 63) / 64;
    c.threads = threads < 1 ? 1 : threads > c.blocks ? c.blocks : threads;
    c.chunks = calloc(c.threads, sizeof(chunk_t));

    // Same two passes as rf_index: quote parity gives each chunk its start state.
    if (c.threads > 1) dispatch_apply_f(c.threads, DISPATCH_APPLY_AUTO, &c, count_quotes);
    bool inside = st->inside;
    for (size_t k = 0; k < c.threads; k++) {
        c.chunks[k].inside = inside;
        inside ^= c.chunks[k].quotes & 1;
    }
    dispatch_apply_f(c.threads, DISPATCH_APPLY_AUTO, &c, scan);

    size_t total = 0;
    for (size_t k = 0; k < c.threads; k++) total += c.chunks[k].count;
    rf_hit *res = total ? malloc(total * sizeof(rf_hit)) : NULL;
    size_t m = 0;
    for (size_t k = 0; k < c.threads; k++) {
        chunk_t *ch = &c.chunks[k];
        for (size_t h = 0; h < ch->count; h++) {
            rf_hit x = ch->hits[h];
            int64_t cell = x.cell >= 0 ? x.cell : st->cell_start;
            if (cell == st->last_hit_cell) continue; // a cell spanning chunks
            st->last_hit_cell = cell;
            res[m++] = (rf_hit){cell, x.row_start >= 0 ? x.row_start : st->row_start, st->rows + x.row};
        }
        st->rows += ch->newlines;
        if (ch->last_nl >= 0) st->row_start = ch->last_nl + 1;
        if (ch->last_bound >= 0) st->cell_start = ch->last_bound + 1;
        free(ch->hits);
    }
    st->inside = c.chunks[c.threads - 1].ends_inside;
    free(c.chunks);
    free(lowered);
    *out = res;
    return m;
}
