// Substring search over CSV bytes, reporting one hit per cell.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// A cell where the needle starts: where the cell and its row start, and the
/// row number (row-ending newlines before the cell).
typedef struct {
    int64_t cell;
    int64_t row_start;
    uint64_t row;
} rf_hit;

/// Carried from one rf_search call to the next. Start with {false, 0, 0, 0, -1}.
typedef struct {
    bool inside;           // `from` is inside quotes
    uint64_t rows;         // row-ending newlines before `from`
    int64_t row_start;     // start of the row containing `from`
    int64_t cell_start;    // start of the cell containing `from`
    int64_t last_hit_cell; // cell of the last hit reported, -1 if none
} rf_search_state;

/// Finds `needle` (raw bytes) starting in [from, to) of p[0..<n] on up to
/// `threads` cores; a match may run past `to` (up to n). `fold`: ASCII
/// case-insensitive, other bytes compare exactly. Cells are split at `delim`
/// and '\n' outside quotes. Hits are in file order, at most one per cell (the
/// cell where the match starts); a match running into the next cell is still
/// reported, so callers verify when the needle holds a delimiter or newline.
/// *out is malloc'd (NULL when there are no hits); the caller frees it.
size_t rf_search(const uint8_t *p, size_t n, size_t from, size_t to, const uint8_t *needle, size_t len,
                 bool fold, uint8_t delim, size_t threads, rf_search_state *st, rf_hit **out);
