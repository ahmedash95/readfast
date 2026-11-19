#include "scan.h"
#include <string.h>

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

uint64_t rf_prefix_xor(uint64_t x) { return rf_pxor(x); }

// Every helper below takes the code unit; callers pass a constant RF_U8 on
// the UTF-8 path so it compiles to exactly the byte loop.

RF_INLINE size_t count_units(const uint8_t *p, size_t n, uint8_t c, rf_unit u) {
    size_t count = 0, i = 0;
    for (; i + RF_STEP(u) <= n; i += RF_STEP(u)) count += (size_t)__builtin_popcountll(rf_eq_units(p + i, u, c));
    if (i < n) {
        uint8_t pad[128] = {0};
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(rf_eq_units(pad, u, c));
    }
    return count;
}

size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c) { return count_units(p, n, c, RF_U8); }

size_t rf_count_units(const uint8_t *p, size_t n, uint8_t c, rf_unit u) {
    return u == RF_U8 ? count_units(p, n, c, RF_U8) : count_units(p, n, c, u);
}

// Units in a padded tail of n - i bytes, minus one: the last real bit.
#define LAST(len, u) ((int)((len) / ((u) == RF_U8 ? 1 : 2)) - 1)

RF_INLINE size_t count_newlines(const uint8_t *p, size_t n, rf_syntax s, uint8_t *state, rf_unit u) {
    size_t count = 0, i = 0;
    rf_carry st = rf_to_carry(*state);
    for (; i + RF_STEP(u) <= n; i += RF_STEP(u))
        count += (size_t)__builtin_popcountll(rf_block(p + i, s, &st, 63, u, NULL, NULL));
    if (i < n) {
        uint8_t pad[128] = {0}; // zeros are neither '"', a delimiter nor a newline
        memcpy(pad, p + i, n - i);
        count += (size_t)__builtin_popcountll(rf_block(pad, s, &st, LAST(n - i, u), u, NULL, NULL));
    }
    *state = rf_from_carry(st);
    return count;
}

RF_INLINE int64_t find_newline(const uint8_t *p, size_t n, uint8_t state, rf_syntax s, uint64_t k, rf_unit u) {
    if (k == 0) return -1;
    rf_carry st = rf_to_carry(state);
    size_t i = 0;
    uint64_t m = 0, c = 0;
    for (; i + RF_STEP(u) <= n; i += RF_STEP(u)) {
        m = rf_block(p + i, s, &st, 63, u, NULL, NULL);
        c = (uint64_t)__builtin_popcountll(m);
        if (c >= k) goto found;
        k -= c;
    }
    if (i < n) {
        uint8_t pad[128] = {0};
        memcpy(pad, p + i, n - i);
        m = rf_block(pad, s, &st, LAST(n - i, u), u, NULL, NULL);
        if ((uint64_t)__builtin_popcountll(m) >= k) goto found;
    }
    return -1;
found:
    while (--k) m &= m - 1; // drop the lower newlines
    return (int64_t)(i + (size_t)__builtin_ctzll(m) * (u == RF_U8 ? 1 : 2));
}

int64_t rf_find_newline_units(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k,
                              rf_unit u) {
    rf_syntax s = {delim, nl};
    return u == RF_U8 ? find_newline(p, n, state, s, k, RF_U8) : find_newline(p, n, state, s, k, u);
}

int64_t rf_find_newline(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k) {
    return find_newline(p, n, state, (rf_syntax){delim, nl}, k, RF_U8);
}

// ── Parallel index ───────────────────────────────────────────────────────────
// The state at a chunk start depends on everything before it, so chunks
// speculate: each guesses its start state from the unit before it (inside a
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
    rf_unit unit;
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
    c->counts[b] = (uint32_t)(c->unit == RF_U8 ? count_newlines(c->p + start, len, c->s, state, RF_U8)
                                                : count_newlines(c->p + start, len, c->s, state, c->unit));
}

static void scan_worker(void *ctx, size_t k) {
    index_ctx *c = ctx;
    size_t first = chunk_first_block(c, k);
    uint8_t state = c->starts[k];
    if (k > 0) { // guess from the previous unit, assuming it's outside quotes
        size_t w = c->unit == RF_U8 ? 1 : 2;
        uint16_t prev = rf_unit_at(c->p + first * c->bs - w, 0, c->unit);
        state = prev == c->s.delim || prev == c->s.nl || prev == '"' ? RF_FIELD : RF_UNQUOTED;
    }
    for (size_t b = first; b < chunk_first_block(c, k + 1); b++) scan_block(c, b, &state);
    c->ends[k] = state;
}

uint8_t rf_index_units(const uint8_t *p, size_t n, size_t bs, size_t threads, uint8_t delim, uint8_t nl,
                       uint8_t start_state, uint32_t *counts, uint8_t *state_at, rf_unit unit) {
    if (n == 0) return start_state;
    size_t blocks = (n + bs - 1) / bs;
    if (threads < 1) threads = 1;
    if (threads > RF_MAX_THREADS) threads = RF_MAX_THREADS;
    if (threads > blocks) threads = blocks;

    index_ctx c = {.p = p, .n = n, .bs = bs, .blocks = blocks, .threads = threads, .s = {delim, nl},
                   .unit = unit, .counts = counts, .state_at = state_at};
    c.starts[0] = start_state;
    rf_parallel(threads, &c, scan_worker);
    uint8_t state = c.ends[0];
    for (size_t k = 1; k < threads; k++) {
        size_t b = chunk_first_block(&c, k), end = chunk_first_block(&c, k + 1);
        while (b < end && state != state_at[b]) scan_block(&c, b++, &state);
        if (b < end) state = c.ends[k]; // converged: the guess's end holds
    }
    return state;
}

uint8_t rf_index(const uint8_t *p, size_t n, size_t bs, size_t threads, uint8_t delim, uint8_t nl,
                 uint8_t start_state, uint32_t *counts, uint8_t *state_at) {
    return rf_index_units(p, n, bs, threads, delim, nl, start_state, counts, state_at, RF_U8);
}

// ── Delimiter sniffing ───────────────────────────────────────────────────────
// Scalar: it reads at most a few rows' worth (64 KB) once per open. In C so
// it stays fast in debug builds too.

size_t rf_sniff_rows(const uint8_t *p, size_t n, uint8_t delim, size_t max_rows, uint32_t *fields, uint32_t *tail,
                     bool *between_digits, rf_unit u) {
    size_t w = u == RF_U8 ? 1 : 2, units = n / w, rows = 0, i = 0, row_start = 0;
    uint32_t f = 1;
    uint8_t state = RF_FIELD;
#define AT(k) rf_unit_at(p, (k), u)
#define DIGIT(c) ((c) >= '0' && (c) <= '9')
    while (i < units && rows < max_rows) {
        uint16_t c = AT(i++);
        if (state == RF_QUOTED) {
            if (c == '"') state = RF_FIELD; // closed: a quote next is "", like at a field start
            continue;
        }
        if (c == '\n' || (c == '\r' && (i == units || AT(i) != '\n'))) {
            fields[rows++] = f;
            f = 1;
            state = RF_FIELD;
            row_start = i;
        } else if (c == delim) {
            f++;
            state = RF_FIELD;
            if (!(i >= 2 && i < units && DIGIT(AT(i - 2)) && DIGIT(AT(i)))) *between_digits = false;
        } else if (c == '"' && state == RF_FIELD) {
            state = RF_QUOTED;
        } else if (c != '\r') {
            state = RF_UNQUOTED;
        }
    }
#undef AT
#undef DIGIT
    *tail = i == units && row_start < units ? f : 0;
    return rows;
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
