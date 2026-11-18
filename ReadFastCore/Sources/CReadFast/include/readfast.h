// SIMD row scanning. A row ends at the newline byte `nl` ('\n', or '\r' for
// classic Mac files) outside a quoted field.
//
// Quote rule (RFC 4180, lenient): a '"' opens a quoted field only as the first
// byte of a field (start of data, after a delimiter or a row end). Inside a
// quoted field "" is an escaped quote and a single '"' closes it; what follows
// up to the next delimiter is plain text. A '"' anywhere else is a plain byte,
// so a stray quote (12,5" pipe,ok) can't swallow the rest of the file.
//
// The scan state between two bytes is RF_FIELD, RF_UNQUOTED or RF_QUOTED.
// Every function only reads [p, p + n): partial 64-byte blocks are copied
// into a zero-padded buffer, so nothing past the end is touched.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RF_FIELD 0    // at a field start (or right after a closing quote: same future)
#define RF_UNQUOTED 1 // inside an unquoted field: quotes are plain bytes
#define RF_QUOTED 2   // inside a quoted field: newlines and delimiters are plain bytes

/// Bit i set <=> block[i] == c. Reads exactly 64 bytes.
uint64_t rf_eq_mask(const uint8_t *block, uint8_t c);

/// Bit i = XOR of bits 0...i. Turns a quote mask into an inside-quotes mask.
uint64_t rf_prefix_xor(uint64_t x);

/// How many bytes in [p, p + n) equal c.
size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c);

/// Sparse index over [p, p + n), split into blocks of `block_size` bytes
/// (a multiple of 64). For block k it writes the number of row-ending
/// newlines in it to counts[k] and the scan state at its start to
/// state_at[k]. `start_state`: the state before p[0] (RF_FIELD at the start
/// of a file, the previous call's result when continuing). Runs on up to
/// `threads` cores. Returns the state after the last byte.
uint8_t rf_index(const uint8_t *p, size_t n, size_t block_size, size_t threads, uint8_t delim, uint8_t nl,
                 uint8_t start_state, uint32_t *counts, uint8_t *state_at);

/// Offset of the k-th (1-based) row-ending newline in [p, p + n) when the
/// scan starts in `state`. -1 if there are fewer than k.
int64_t rf_find_newline(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k);
