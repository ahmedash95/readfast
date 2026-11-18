// SIMD row scanning. A row ends at the newline unit `nl` ('\n', or '\r' for
// classic Mac files) outside a quoted field.
//
// Quote rule (RFC 4180, lenient): a '"' opens a quoted field only as the first
// unit of a field (start of data, after a delimiter or a row end). Inside a
// quoted field "" is an escaped quote and a single '"' closes it; what follows
// up to the next delimiter is plain text. A '"' anywhere else is a plain unit,
// so a stray quote (12,5" pipe,ok) can't swallow the rest of the file.
//
// The scan state between two units is RF_FIELD, RF_UNQUOTED or RF_QUOTED.
// Every function only reads [p, p + n): partial 64-unit blocks are copied
// into a zero-padded buffer, so nothing past the end is touched.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RF_FIELD 0    // at a field start (or right after a closing quote: same future)
#define RF_UNQUOTED 1 // inside an unquoted field: quotes are plain units
#define RF_QUOTED 2   // inside a quoted field: newlines and delimiters are plain units

/// Code unit of the scanned data. Offsets and lengths stay in bytes; in the
/// UTF-16 modes they must be even and a 64-bit mask covers 64 units (128 bytes).
/// The delimiter and newline are ASCII and compared as whole units.
typedef enum { RF_U8, RF_U16LE, RF_U16BE } rf_unit;

/// Bit i set <=> block[i] == c. Reads exactly 64 bytes.
uint64_t rf_eq_mask(const uint8_t *block, uint8_t c);

/// Bit i set <=> 16-bit lane i of block (read little-endian) == c. Reads exactly 128 bytes.
uint64_t rf_eq_mask16(const uint8_t *block, uint16_t c);

/// Bit i = XOR of bits 0...i. Turns a quote mask into an inside-quotes mask.
uint64_t rf_prefix_xor(uint64_t x);

/// How many bytes in [p, p + n) equal c.
size_t rf_count_byte(const uint8_t *p, size_t n, uint8_t c);

/// How many units of `unit` in [p, p + n) equal the ASCII char c.
size_t rf_count_units(const uint8_t *p, size_t n, uint8_t c, rf_unit unit);

/// Sparse index over [p, p + n), split into blocks of `block_size` bytes
/// (a multiple of 64 units). For block k it writes the number of row-ending
/// newlines in it to counts[k] and the scan state at its start to
/// state_at[k]. `start_state`: the state before p[0] (RF_FIELD at the start
/// of a file, the previous call's result when continuing). Runs on up to
/// `threads` cores. Returns the state after the last unit.
uint8_t rf_index_units(const uint8_t *p, size_t n, size_t block_size, size_t threads, uint8_t delim, uint8_t nl,
                       uint8_t start_state, uint32_t *counts, uint8_t *state_at, rf_unit unit);

/// Offset in bytes of the k-th (1-based) row-ending newline in [p, p + n)
/// when the scan starts in `state`. -1 if there are fewer than k.
int64_t rf_find_newline_units(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k,
                              rf_unit unit);

/// rf_index_units / rf_find_newline_units over bytes (UTF-8, Windows-1252).
uint8_t rf_index(const uint8_t *p, size_t n, size_t block_size, size_t threads, uint8_t delim, uint8_t nl,
                 uint8_t start_state, uint32_t *counts, uint8_t *state_at);
int64_t rf_find_newline(const uint8_t *p, size_t n, uint8_t state, uint8_t delim, uint8_t nl, uint64_t k);

/// Delimiter sniffing: splits [p, p + n) into rows (ending at '\n', "\r\n" or a
/// lone '\r' outside quoted fields) and fields at `delim`, with the quote rule
/// above. Writes the field count of up to `max_rows` rows to `fields` and
/// returns how many; *tail = fields of a last row without a newline (0: none).
/// *between_digits is cleared when a delimiter isn't between two digits.
size_t rf_sniff_rows(const uint8_t *p, size_t n, uint8_t delim, size_t max_rows, uint32_t *fields, uint32_t *tail,
                     bool *between_digits, rf_unit unit);

/// Zero bytes in [p, p + n) at even and at odd offsets (encoding detection).
void rf_count_zeros(const uint8_t *p, size_t n, size_t *even, size_t *odd);

/// Whether [p, p + n) is valid UTF-8. `allow_cut`: a sequence cut off by the
/// end of the buffer counts as valid (the buffer is a sample of a longer file).
bool rf_utf8_valid(const uint8_t *p, size_t n, bool allow_cut);
