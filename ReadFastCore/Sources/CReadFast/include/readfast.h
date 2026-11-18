// SIMD row scanning. A row ends at '\n' outside double quotes.
// Every function only reads [p, p + n): partial 64-byte blocks are copied
// into a zero-padded buffer, so nothing past the end is touched.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Code unit of the scanned data. Offsets and lengths stay in bytes; in the
/// UTF-16 modes they must be even and a 64-bit mask covers 64 units (128 bytes).
typedef enum { RF_U8, RF_U16LE, RF_U16BE } rf_unit;

/// Bit i set <=> block[i] == c. Reads exactly 64 bytes.
uint64_t rf_eq_mask(const uint8_t *block, uint8_t c);

/// Bit i set <=> 16-bit lane i of block (read little-endian) == c. Reads exactly 128 bytes.
uint64_t rf_eq_mask16(const uint8_t *block, uint16_t c);

/// Bit i = XOR of bits 0...i. Turns a quote mask into an inside-quotes mask.
uint64_t rf_prefix_xor(uint64_t x);

/// How many bytes in [p, p + n) equal c.
size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c);

/// Sparse index over [p, p + n), split into blocks of `block_size` bytes
/// (a multiple of 64). For block k it writes the number of row-ending
/// newlines in it to counts[k] and whether it starts inside quotes to
/// inside_at[k]. `start_inside`: whether p[0] is inside quotes (true when
/// continuing a previous call). Runs on up to `threads` cores. Returns
/// whether the data ends inside quotes.
bool rf_index(const uint8_t *p, size_t n, size_t block_size, size_t threads, bool start_inside,
              uint32_t *counts, uint8_t *inside_at);

/// Offset of the k-th (1-based) row-ending newline in [p, p + n) when the
/// scan starts inside quotes or not. -1 if there are fewer than k.
int64_t rf_find_newline(const uint8_t *p, size_t n, bool inside, uint64_t k);

/// rf_index / rf_find_newline over code units of `unit` ('"' and '\n' are
/// one unit each). Block size must be a multiple of 64 units.
bool rf_index_units(const uint8_t *p, size_t n, size_t block_size, size_t threads, bool start_inside,
                    uint32_t *counts, uint8_t *inside_at, rf_unit unit);
int64_t rf_find_newline_units(const uint8_t *p, size_t n, bool inside, uint64_t k, rf_unit unit);
