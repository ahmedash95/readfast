import Foundation
import ReadFastCore

/// Format overrides for one file; nil = let the engine detect it.
struct CSVOptions: Hashable {
    var encoding: CSVEncoding?
    var delimiter: UInt8?
    var hasHeader: Bool?
}

/// One open CSV file: the Linux twin of the macOS app's `CSVTable` (ReadFast/CSVTable.swift),
/// minus the main actor. Everything here runs on the GTK main thread; background work
/// (indexing, search) reports back through `onMain`, and `onChange` tells the window to redraw.
final class Document {
    let url: URL
    let options: CSVOptions
    /// What the engine detected, for "Automatic (…)" in the menu; carried over for forced settings.
    let detected: CSVOptions
    /// Column names: the header row, or "Column 1…" without one (and for columns wider than it).
    let header: [String]
    let file: CSVFile
    var onChange: () -> Void = {}

    /// Data rows (header excluded). Estimated until `isExact`.
    private(set) var rowCount = 0
    private(set) var isExact = false
    private(set) var progress = 0.0

    // Find: matches in file order (raw file rows), capped like the Mac app.
    static let maxStoredMatches = 1_000_000
    private(set) var matches: [SearchMatch] = []
    private(set) var searchTotal = 0
    private(set) var isSearching = false
    private(set) var currentMatch: Int?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    /// Overrides chosen in the Format menu, per file, for this session.
    static var sessionOptions: [URL: CSVOptions] = [:]
    static let previewRows = 100

    init(url: URL, options: CSVOptions? = nil, previous: Document? = nil) throws {
        let options = options ?? Self.sessionOptions[url] ?? CSVOptions()
        Self.sessionOptions[url] = options
        let file = try CSVFile.open(url, encoding: options.encoding, delimiter: options.delimiter, hasHeader: options.hasHeader)
        self.file = file
        self.url = url
        self.options = options
        let before = previous?.detected
        detected = CSVOptions(encoding: options.encoding == nil ? file.encoding : before?.encoding,
                              delimiter: options.delimiter == nil ? file.delimiter : before?.delimiter,
                              hasHeader: options.hasHeader == nil ? file.hasHeader : before?.hasHeader)
        let preview = (0..<min(file.availableRows, Self.previewRows)).compactMap { file.row($0) }
        header = Self.columnNames(header: file.hasHeader ? preview.first : nil, width: preview.map(\.count).max() ?? 0)
        refresh()
    }

    deinit { searchTask?.cancel() }

    /// Indexes the whole file on every core; `onChange` fires as rows become readable.
    func startIndexing() {
        let file = file
        Task.detached { await file.indexAll() }
        every(ms: 100) { [weak self] in
            guard let self else { return false }
            refresh()
            onChange()
            return !isExact
        }
    }

    private func refresh() {
        rowCount = max(0, file.rowCount.value - headerRows)
        isExact = file.isIndexed
        progress = file.indexedFraction
    }

    private var headerRows: Int { file.hasHeader ? 1 : 0 }

    /// Fields of data row `row`; empty while the index hasn't reached it.
    func fields(at row: Int) -> [String] { file.row(row + headerRows) ?? [] }

    static func columnNames(header: [String]?, width: Int) -> [String] {
        let header = header ?? []
        return header + (header.count..<max(width, header.count)).map { "Column \($0 + 1)" }
    }

    // MARK: Find

    /// Replaces the matches with those of `query`, streaming them in as the scan goes.
    func search(_ query: String) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        matches = []
        searchTotal = 0
        currentMatch = nil
        isSearching = !query.isEmpty && file.supportsSearch
        onChange()
        guard isSearching else { return }
        let file = file, headerRows = headerRows
        searchTask = Task.detached { [weak self] in
            var headerMatches = 0
            for await step in file.search(query) {
                if Task.isCancelled { return }
                var found: [SearchMatch] = []
                for match in step.matches {
                    if match.row < headerRows { headerMatches += 1 } else { found.append(match) }
                }
                let total = step.total - headerMatches, done = step.isComplete
                onMain {
                    guard let self, self.searchGeneration == generation else { return }
                    self.matches += found.prefix(Self.maxStoredMatches - self.matches.count)
                    self.searchTotal = total
                    if done { self.isSearching = false }
                    self.onChange()
                }
            }
        }
    }

    /// Moves to the next (1) or previous (-1) match, wrapping; returns it as (data row, column).
    func stepMatch(by delta: Int) -> (row: Int, column: Int)? {
        guard let i = Self.step(currentMatch, by: delta, count: matches.count) else { return nil }
        currentMatch = i
        return (matches[i].row - headerRows, matches[i].column)
    }

    /// Columns of data row `row` that match, and which of them is the current match.
    func matchedColumns(inRow row: Int) -> (columns: [Int], current: Int?) {
        guard !matches.isEmpty else { return ([], nil) }
        let fileRow = row + headerRows
        var i = Self.firstIndex(atOrAfter: fileRow, in: matches.lazy.map(\.row))
        var columns: [Int] = [], current: Int?
        while i < matches.count, matches[i].row == fileRow {
            columns.append(matches[i].column)
            if i == currentMatch { current = matches[i].column }
            i += 1
        }
        return (columns, current)
    }

    static func firstIndex(atOrAfter value: Int, in sorted: some RandomAccessCollection<Int>) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[sorted.index(sorted.startIndex, offsetBy: mid)] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func step(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }
}

// MARK: Names for the Format menu and status line

let delimiters: [(key: String, byte: UInt8)] = [("comma", 44), ("semicolon", 59), ("tab", 9), ("pipe", 124)]

func delimiterName(_ byte: UInt8) -> String {
    switch byte {
    case 44: "Comma"
    case 59: "Semicolon"
    case 9: "Tab"
    case 124: "Pipe"
    default: "“\(Character(Unicode.Scalar(byte)))”"
    }
}

extension CSVEncoding {
    var name: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .windows1252: "Windows-1252"
        }
    }
}

func formatCount(_ n: Int) -> String {
    let digits = String(n)
    var out = ""
    for (i, c) in digits.enumerated() {
        if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(c)
    }
    return out
}

func formatBytes(_ n: Int) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var value = Double(n), unit = 0
    while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
    return unit == 0 ? "\(n) bytes" : String(format: value < 10 ? "%.1f" : "%.0f", value) + " " + units[unit]
}
