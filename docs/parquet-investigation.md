# Parquet support for ReadFast: investigation

Research only, 2026-11-18. **[M]** = measured on this Mac (Apple Silicon, warm page cache) with scripts and files in a scratchpad; **[I]** = inferred or from docs. Test files: 40M rows × 8 columns (int64, timestamp, double, int32, 2 dictionary strings, free text, `list<string>`), 1M-row row groups, 1 MB pages: 1.40 GB Snappy, 0.87 GB Zstd. Also 10M rows in 200 row groups, and 500 columns × 100 row groups.

## 1. Format fit

- **Schema and exact row count are in the footer.** Open = read the last 8 bytes, then the Thrift footer. Footer 46 KB, parse 0.5–1.1 ms; with 200 row groups 214 KB / 1.4 ms **[M]**. Wide files are the outlier: 500 cols × 100 RGs gives a 5.9 MB footer and a 29 ms parse **[M]**. So `rowCount` is `.exact` at open and needs no indexing pass.
- **Random access is per row group, then per page.** Footer row counts map row *i* to a row group with a binary search. Inside it, each column is its own chunk of pages, and page boundaries differ by column. The optional **page index** (OffsetIndex: first row of each page) lets a reader decode only the pages that hold rows *i…i+n*. Without it, a reader has to walk the pages from the start of the row group. pyarrow doesn't write a page index by default **[I]**, so expect many files without one.
- **Encodings:** every column here used `PLAIN` + `RLE_DICTIONARY` (+ RLE/bit-packed levels) **[M]**. Real files also use `DELTA_*` and `BYTE_STREAM_SPLIT` **[I]**. A dictionary column needs its dictionary page decoded once per chunk.
- **Codecs:** Snappy (Spark/DuckDB default) and Zstd (Polars default) cover most files **[I]**. Apple's Compression framework has ZLIB (gzip, after stripping the header), LZ4_RAW and Brotli (macOS 12+), but **no Snappy and no Zstd** **[M, SDK header]**. Decompressing a 1 MB page: Snappy 0.46 ms, Zstd 0.28, LZ4 0.22, Gzip 0.70, Brotli 0.58 **[M]**.
- **Nested types** (list/map/struct) need definition/repetition levels. Show them as JSON-ish text in a cell.

## 2. Implementation options

| Option | Size | Build / license | Verdict |
|---|---|---|---|
| Arrow C++ (parquet-cpp, Arrow 26) | libarrow 39 MB + libparquet 4.7 MB **[M, pyarrow wheel]** | CMake, many deps, painful to bring into Xcode; Apache-2.0 | Too heavy |
| DuckDB C API (2.0.0) | ~50 MB lib **[M]** | Easy (SwiftPM `duckdb-swift`); MIT | Fetching 200 rows with `LIMIT/OFFSET` took **27–106 ms** **[M]**: SQL offsets don't seek pages. Overkill |
| **arrow-rs `parquet` 59.3.3, Rust staticlib + C ABI** | **3.5 MB** (Snappy+Zstd), **4.7 MB** (all codecs), stripped LTO binary **[M]** | Needs a Rust toolchain + a build script for an xcframework; Apache-2.0; monthly releases | **Best fit** |
| Swift libs | ParquetKit 1.1.1 (wraps arrow-rs, Codable, sequential reads only); parquet-swift (incomplete) **[I, web]** | — | Not for random access |
| Own C/Swift reader | ~0.3 MB + vendored zstd-decompress (BSD) + Snappy decompressor (~200 lines) **[I]** | No new toolchain | Viable, but a long tail (DELTA_*, nesting, INT96, logical types, odd writers) |

## 3. API fit

The UI already uses only `header`, `rowCount`, `isExact`, `progress`, `fields(at:)`, `byteCount`. A `ParquetFile` can fill the same surface:

- `header` comes from the schema, not row 0. `rowCount` is exact at open, so `isExact = true` and `progress = 1`.
- **"Indexing" for Parquet is just the footer** (+ page index, ~3 ms here **[M]**). Nothing scans the whole file.
- `fields(at:)` returns cells from a decoded-block cache, or `[]` (the existing placeholder path) on a miss. The miss queues a background decode and calls `refresh()`/`reloadData` for those rows when it's done. This is the same contract as "not indexed yet" for CSV.
- Values are formatted to `String` in the engine (Arrow's display formatter: timestamps, decimals, lists as `[a, b]`). Typed values and column-at-a-time fetching can wait.

Smallest change: put `CSVTable`'s surface behind one protocol, or one enum backing, chosen by file extension.

## 4. Performance

- **Open:** 1–4 ms for 1–10 GB files with tens to hundreds of row groups **[M at 1.4 GB; I at 10 GB]**. 30 ms+ only for very wide files.
- **Cache miss** (decode 200 rows, all columns, at a random spot) with arrow-rs: **7–15 ms with a page index, 25–27 ms without** (1M-row RGs) **[M]**. pyarrow takes 37–39 ms to decode a whole row group **[M]**. Misses must stay off the main thread, but each one is only a frame or two of placeholder.
- **Cache hit:** formatting one row to `[String]` takes **0.6–0.7 µs** **[M]**, against today's ~6 µs for CSV.
- **Cache:** fixed 1024-row blocks, decoded on a background queue into formatted cells for all columns (or only visible ones for 100+ column files). LRU of ~64 blocks (a few MB) **[I]**. Prefetch one block ahead in the scroll direction. Keep one open reader with its parsed footer: the measured miss included reopening and re-parsing the footer, about 1–3 ms. Fast scrolling at ~170 rows/s crosses a block every ~6 s, so with prefetch, misses only show when you jump with the scroller.

## 5. Recommendation

**Wrap arrow-rs `parquet` in a Rust staticlib with a ~5-function C ABI, shipped as an xcframework that `ReadFastCore` links.** C ABI: `pq_open`, `pq_schema`, `pq_row_count`, `pq_read_block(start, n, cols) → UTF-8 cells`, `pq_close`. It handles every encoding, codec and nested type, has a page-index-aware `RowSelection`, adds ~3.5–4.7 MB, and is Apache-2.0 and actively maintained. Swift wraps it as `ParquetFile` with an LRU block cache.

- **Effort [I]:** ~1 week for the engine + xcframework build script, plus ~3–5 days for UI wiring, the cache and tests.
- **Risks:** Rust becomes a build dependency (prebuild and commit the xcframework, or add a build phase); universal arm64+x86_64 builds; panics at the FFI boundary (`panic=abort` or `catch_unwind`); huge-footer files; sandbox is fine, since it reads via a file descriptor from `open`.
- **Fallback if Rust is unacceptable:** an own C reader covering flat columns, PLAIN/RLE_DICTIONARY/RLE, Snappy (own code) + Zstd (vendored decompressor) + Gzip/LZ4/Brotli via Compression.framework. Roughly 3–5 weeks plus the long tail.

**First milestone:** open a `.parquet` file, show the schema as the header and the exact row count instantly, and show the first 1,000 rows of flat Snappy/Zstd files. Nested cells appear as text. Done when the 1.4 GB test file opens in under 10 ms and a cache hit costs under 5 µs per row.

## Sources

- arrow-rs releases: https://github.com/apache/arrow-rs, https://newreleases.io/project/github/apache/arrow-rs/release/59.2.0
- DuckDB Swift: https://duckdb.org/docs/2.0/clients/tertiary_clients/swift; DuckDB Parquet defaults: https://duckdb.org/2025/01/22/parquet-encodings.html
- ParquetKit: https://swiftpackageregistry.com/AlexLike/ParquetKit
- Polars default Zstd: https://docs.pola.rs/api/python/stable/reference/api/polars.DataFrame.write_parquet.html
- Apple Compression: `compression.h` in the macOS 27 SDK
- Measured with pyarrow 26.0.1, duckdb 2.0.0, parquet crate 59.3.3 (scripts: `bench.py`, `bench2.py`, `rsproto/` in the session scratchpad)
