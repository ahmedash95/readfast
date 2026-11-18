# ReadFastCore

The CSV engine for ReadFast. A local Swift package (`ReadFastCore/`) that the
app target already links. The app imports it and uses one class: `CSVFile`.

```swift
import ReadFastCore
```

## What it does

- **Opens instantly at any size.** The file is `mmap`ed; nothing is read until a
  page is touched. `open` indexes only the first 512 KB (~10 ms).
- **Indexes the rest in the background**, front to back in 64 MB segments, on all
  cores (~18 GB/s warm cache; cold files are limited by SSD speed). Rows become
  readable segment by segment.
- **Small memory at any size.** File bytes live in the OS page cache, not the
  app. The row index is ~1.4 MB per 10 GB.
- **Thread-safe.** Every member can be called from any thread, including main.

## API

```swift
public final class CSVFile: Sendable {
    public static func open(_ url: URL, delimiter: UInt8? = nil, hasHeader: Bool? = nil,
                            previewBytes: Int = defaultPreviewBytes) throws -> CSVFile   // nil = detect

    public func row(_ i: Int) -> [String]?   // fields of row i; nil = past the end OR not indexed yet
    public var availableRows: Int            // rows row(_:) can return right now

    public var rowCount: RowCount            // .estimated(n) while indexing, .exact(n) when done
    public var isIndexed: Bool               // true when rowCount is exact
    public var indexedFraction: Double       // 0...1
    public func indexAll(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async

    public let delimiter: UInt8              // detected from preview rows (, ; \t |) or forced
    public let hasHeader: Bool               // is row 0 a header? detected from preview rows or forced
    public let byteCount: Int                // file size

    public static let defaultPreviewBytes: Int   // 512 KB
    public static let maxRowBytes: Int           // 1 MB; longer rows are cut when read
}

public enum RowCount: Equatable, Sendable {
    case exact(Int), estimated(Int)
    public var value: Int
}
```

### Semantics to get right

| Thing | Rule |
|---|---|
| Row numbering | Row 0 is always the first line of the file, whatever `hasHeader` says. Let `h = hasHeader ? 1 : 0`: header is `hasHeader ? row(0) : nil` (show `Column 1…` names otherwise), data row `i` is `row(i + h)`, data row count is `max(0, rowCount.value - h)`. |
| Delimiter | Detected once in `open` from up to 50 preview rows: among `, ; \t \|`, the one whose field count (> 1, quotes respected) is the same on the most rows, then the one with more fields. A title/comment line or ragged rows don't sway it; `1,5;2,7` (decimal commas) picks `;`. No fit (one column, empty file) → `,`. `:` and space are never detected (times and prose fool them); force them if needed. |
| Header | Detected once in `open` from the same rows: a text cell over a numeric/date column votes header; a number/date over one votes no; a top cell repeated in its text column votes no; duplicate names or 2+ empty names vote no. Ties (e.g. all-text tables) → header. A single row is a header if its cells are distinct non-empty text. Empty file → `false`. |
| Overrides | `open(url, delimiter: UInt8(ascii: ";"), hasHeader: false)` uses the values as given (any byte except `"`/newlines works as delimiter). Pass nil (default) to detect. To change them from the toolbar, re-`open` the URL (it's ~10 ms) and restart `indexAll`. Forcing only the delimiter still detects the header with that delimiter. |
| Fields | Already split and unquoted: `"Smith, J"` → `Smith, J`, `""` → `"`. Quoted newlines stay inside the field. Trailing `\r` is stripped. A UTF-8 BOM is skipped. Invalid UTF-8 becomes `�`. |
| Ragged rows | Rows can have more or fewer fields than the header. Pad/ignore in the UI; never index blindly. |
| `row(i) == nil` | Either `i >= rowCount` or the index hasn't reached row `i` yet. Check `i < availableRows` to tell them apart; show a placeholder row while indexing. |
| Row count | `.estimated` is projected from the bytes scanned so far and improves after each segment; it can move, so the scroll height may change slightly until `.exact`. |
| `indexAll` | Call once per file, right after `open`. Returns when the count is exact. Calling again after that is a no-op. `onProgress` runs on a **background thread**. |
| Errors | `open` throws `POSIXError` (missing file, no permission). Empty files open fine: 0 rows. |
| Lifetime | Keep the `CSVFile` alive while it's on screen; dropping the last reference unmaps the file. |

## Sandbox

The app is sandboxed with user-selected read-only files. URLs from
`.fileImporter` / `NSOpenPanel` / drag and drop need security-scoped access
around `open`:

```swift
let ok = url.startAccessingSecurityScopedResource()
defer { if ok { url.stopAccessingSecurityScopedResource() } }
let file = try CSVFile.open(url)   // the mapping stays valid after access stops
```

## Wiring it into SwiftUI

`open` and `row(_:)` are cheap and synchronous. Only `indexAll` is long, and it
already runs off the calling thread. Recommended shape:

```swift
import ReadFastCore
import SwiftUI

@MainActor @Observable
final class CSVModel {
    private(set) var file: CSVFile?
    private(set) var header: [String] = []
    private(set) var rowCount = 0          // data rows (header excluded)
    private(set) var isExact = false
    private(set) var progress = 0.0        // 0...1, for the top bar
    private(set) var error: Error?

    func open(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let f = try CSVFile.open(url)          // instant
            file = f
            header = f.row(0) ?? []
            refresh()                              // preview is visible now
            await f.indexAll { fraction in
                Task { @MainActor [weak self] in
                    self?.progress = fraction
                    self?.refresh()                // more rows + better estimate
                }
            }
            refresh()                              // exact
        } catch {
            self.error = error
        }
    }

    /// Fields for data row `i` (0-based, header excluded). nil = not indexed yet.
    func row(_ i: Int) -> [String]? { file?.row(i + 1) }

    private func refresh() {
        guard let f = file else { return }
        rowCount = max(0, f.rowCount.value - 1)
        isExact = f.isIndexed
        progress = f.indexedFraction
    }
}
```

Table guidelines:

- Use a lazy, virtualized list (`List`/`LazyVStack` with `ForEach(0..<model.rowCount, id: \.self)`,
  or `NSTableView` for 10M+ rows). Call `model.row(i)` only for rows being drawn;
  never materialize all rows.
- Size the scroll content from `rowCount`. While `!isExact`, show it as approximate
  (e.g. `~1.2M rows`) and a progress bar from `progress`.
- For `row(i) == nil` inside `rowCount`, draw a placeholder; it fills in when
  indexing passes it (the model's `refresh()` triggers a redraw).
- Column count: `header.count`, but rows may be wider; take the max of what's visible.

## Migrating the current app (`ReadFast/CSVTable.swift` stand-in)

`CSVTable` is a placeholder: serial byte loop, a full in-memory row index
(8 bytes per row), and `,` hardcoded. Replace its internals with `CSVFile` and
keep its surface so `CSVDocument.swift` barely changes:

| `CSVTable` today | Backed by `CSVFile` |
|---|---|
| `static func load(_ url:) async throws` | `CSVFile.open(url)` (sync, ~10 ms), then start `indexAll` |
| `header` | `file.row(0) ?? []` |
| `rowCount` (data rows) | `max(0, file.rowCount.value - 1)`; **changes while indexing** |
| `fields(at: row)` | `file.row(row + 1)`; **nil while not indexed** |
| `byteCount` | `file.byteCount` |
| (new) | `isExact = file.isIndexed`, `progress = file.indexedFraction` |

Three things in the current UI that break with a progressive engine:

1. **`rowCount` is no longer constant.** Make `CSVTable` `@MainActor @Observable`
   (like `CSVModel` above), update `rowCount`/`progress` from `indexAll`'s
   `onProgress`, and in `CSVGrid.updateNSView` call
   `tableView.noteNumberOfRowsChanged()` (plus `reloadData()` for rows that just
   became readable) when `rowCount` changed. Do it **before** the existing
   `guard coordinator.fontSize != fontSize else { return }`, which returns early.
2. **Don't cache a missing row.** `Coordinator` caches the last row's fields
   (`cachedRow`). If `row(i)` returned nil (not indexed yet), draw empty cells but
   leave `cachedRow` unchanged, or the row stays blank after indexing reaches it.
3. **Status pill.** It shows `ProgressView` + "Indexing…" until `load` returns,
   but `open` now returns almost immediately. Show the row count as `~1.2M` plus
   a small progress indicator while `!isExact`, then the exact count.

The delimiter is now sniffed (`; \t |` work), so nothing in the UI should assume
`,`. Row 0 is no longer always the header: use `file.hasHeader` (see the Row
numbering rule) and offer toolbar overrides for delimiter and header. `DocumentGroup`'s `fileURL` already carries sandbox access; wrapping
`open` in `startAccessingSecurityScopedResource()` is harmless and covers URLs
from other sources (launcher recents, drag and drop).

## Building and testing the package

```sh
cd ReadFastCore
swift test                                   # 32 tests, ~3 s
RF_BENCH=1 swift test -c release --filter benchmark   # open / index GB/s on a 1 GB file
```

Tests use tiny block and segment sizes, so 2 KB inputs exercise the same paths as
a 10 GB file: SIMD primitives vs scalar, quotes split across threads and
segments, preview → progressive → exact index, a 4 GB sparse file opening in
< 200 ms without being read, and runaway (unclosed-quote) rows.

## Layout (for changing the engine, not for using it)

```
Sources/CReadFast/        C + NEON: 64-byte masks, prefix-XOR quote tracking, parallel block index
Sources/ReadFastCore/
  CSVFile.swift           public API: mmap, preview, progressive indexAll
  RowIndex.swift          sparse index: newlines per 64 KB block, row lookup = binary search + 1 block scan
  Fields.swift            row → fields (scalar; only runs on visible rows)
  Detection.swift         delimiter + header detection from preview rows (runs once in open)
```

Known limits: Intel Macs / x86 simulators use a slower scalar path; a file
truncated by another process while open crashes on read (SIGBUS).
