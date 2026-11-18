import Darwin
import Dispatch
import Foundation
import Synchronization

public enum RowCount: Equatable, Sendable {
    case exact(Int)
    case estimated(Int)

    public var value: Int {
        switch self { case .exact(let n), .estimated(let n): n }
    }
}

/// A CSV file, memory-mapped.
///
///     let file = try CSVFile.open(url)  // mmap + index of the first 512 KB: instant
///     file.row(0)                       // header, readable right away
///     file.rowCount                     // .estimated(...) until indexed
///     await file.indexAll()             // whole file on every core, off the caller's thread
///     file.rowCount                     // .exact(...)
///
/// Row 0 is the first line of the file (usually the header). Memory stays
/// small at any file size: the bytes are the page cache's, not ours, and the
/// index is ~1.4 MB per 10 GB. Every method is safe to call from any thread.
///
/// In a sandboxed app, call `url.startAccessingSecurityScopedResource()`
/// before `open`. The mapping stays valid after that access ends.
public final class CSVFile: @unchecked Sendable { // bytes are read-only; the index is behind a Mutex
    public static let defaultPreviewBytes = 512 << 10
    /// Rows longer than this are cut when read, so one runaway row (an
    /// unclosed quote in a 10 GB file) can't turn into a 10 GB String.
    public static let maxRowBytes = 1 << 20

    /// Sniffed from the preview rows (`, ; \t |`), unless forced in `open`.
    public let delimiter: UInt8
    /// Whether row 0 is a header (detected from the preview rows, unless forced in
    /// `open`). `row(_:)` ignores it: row 0 is always the first line.
    public let hasHeader: Bool
    /// File size in bytes.
    public let byteCount: Int

    private let region: UnsafeMutableRawPointer?
    let data: UnsafeRawBufferPointer // the mapped bytes after a UTF-8 BOM
    private let blockSize: Int
    private let index: Mutex<RowIndex>

    /// `delimiter` / `hasHeader`: nil = detect from the preview, a value = use it as is.
    public static func open(_ url: URL, delimiter: UInt8? = nil, hasHeader: Bool? = nil, previewBytes: Int = defaultPreviewBytes) throws -> CSVFile {
        try CSVFile(url: url, previewBytes: previewBytes, blockSize: 64 << 10, delimiter: delimiter, hasHeader: hasHeader)
    }

    init(url: URL, previewBytes: Int, blockSize: Int, delimiter forcedDelimiter: UInt8? = nil, hasHeader forcedHeader: Bool? = nil) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) } // the mapping outlives the descriptor
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let len = Int(st.st_size)

        // ponytail: if another process truncates the file while it's mapped, reading
        // past the new end raises SIGBUS. Copy-on-open would fix it at the cost of memory.
        if len > 0 {
            let p = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0)
            guard let p, p != MAP_FAILED else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            region = p
        } else {
            region = nil
        }
        let all = UnsafeRawBufferPointer(start: region, count: len)
        let bom = len >= 3 && all[0] == 0xEF && all[1] == 0xBB && all[2] == 0xBF
        let data = bom ? UnsafeRawBufferPointer(rebasing: all[3...]) : all
        self.data = data
        byteCount = len
        self.blockSize = blockSize

        // Preview: index only the first `previewBytes` (whole blocks), serially.
        let preview = min(data.count, max(blockSize, previewBytes / blockSize * blockSize))
        let idx = RowIndex.build(data, upTo: preview, blockSize: blockSize, threads: 1)
        // Detection sample: the first rows the preview serves, or, if row 0 doesn't
        // end inside the preview, its start.
        var sample = (0..<min(idx.availableRows(data), Fields.sampleRows)).compactMap { i in
            idx.rowRange(i, data).map { UnsafeRawBufferPointer(rebasing: data[$0.lowerBound..<min($0.upperBound, $0.lowerBound + Fields.sampleRowBytes)]) }
        }
        if sample.isEmpty, !data.isEmpty { sample = [UnsafeRawBufferPointer(rebasing: data[..<min(data.count, Fields.sampleRowBytes)])] }
        let delimiter = forcedDelimiter ?? Fields.sniffDelimiter(sample)
        self.delimiter = delimiter
        hasHeader = forcedHeader ?? Fields.detectHeader(sample.map { Fields.split($0, delimiter: delimiter) })
        index = Mutex(idx)
    }

    deinit {
        if let region { munmap(region, byteCount) }
    }

    /// Whether the whole file has been indexed (always true for small files).
    public var isIndexed: Bool { index.withLock { $0.isComplete } }

    /// Exact once indexed; before that, estimated from the preview.
    public var rowCount: RowCount {
        let idx = index.withLock { $0 }
        return idx.rowCount(data)
    }

    /// Rows `row(_:)` can return right now.
    public var availableRows: Int {
        let idx = index.withLock { $0 }
        return idx.availableRows(data)
    }

    /// Fields of row `i`, or nil if it doesn't exist (or isn't indexed yet).
    public func row(_ i: Int) -> [String]? {
        let idx = index.withLock { $0 }
        guard let r = idx.rowRange(i, data) else { return nil }
        let cut = r.lowerBound..<min(r.upperBound, r.lowerBound + Self.maxRowBytes)
        return Fields.split(UnsafeRawBufferPointer(rebasing: data[cut]), delimiter: delimiter)
    }

    /// Share of the file indexed so far, 0...1.
    public var indexedFraction: Double { index.withLock { $0.fraction } }

    /// Index the whole file on every core, off the caller's thread, front to
    /// back in 64 MB segments. After each segment, the rows in it become
    /// readable, `rowCount` gets a better estimate, and `onProgress` gets the
    /// fraction done (on a background thread; hop to the main actor for UI).
    /// Returns when the count is exact. Calling it again after that is a no-op.
    public func indexAll(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        await indexAll(threads: ProcessInfo.processInfo.activeProcessorCount, segmentBytes: 64 << 20, onProgress: onProgress)
    }

    func indexAll(threads: Int, segmentBytes: Int = 64 << 20, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        if isIndexed { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = RowIndex.build(self.data, upTo: self.data.count, blockSize: self.blockSize, threads: threads, segmentBytes: segmentBytes) { partial in
                    // never step back, e.g. behind a bigger preview or a concurrent call
                    self.index.withLock { if partial.scanned > $0.scanned { $0 = partial } }
                    onProgress(partial.fraction)
                }
                done.resume()
            }
        }
    }

    var indexSnapshot: RowIndex { index.withLock { $0 } }
}
