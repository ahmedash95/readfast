import Foundation

/// Stand-in for the SIMD engine. The UI only needs this surface: `load`, `header`, `rowCount`, `fields(at:)`.
/// ponytail: serial byte loop + full row index; the engine's SIMD scan + sparse 1/1024 index replaces it.
nonisolated final class CSVTable: Sendable {
    let header: [String]
    let rowCount: Int
    var byteCount: Int { data.count }
    private let data: Data
    private let rowStarts: [Int]   // rowStarts[0] is the header

    @concurrent static func load(_ url: URL) async throws -> CSVTable {
        try CSVTable(url: url)
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var starts: [Int] = data.isEmpty ? [] : [0]
        data.withUnsafeBytes { bytes in
            var inQuotes = false
            for i in bytes.indices {
                switch bytes[i] {
                case UInt8(ascii: "\""): inQuotes.toggle()
                case UInt8(ascii: "\n") where !inQuotes && i + 1 < bytes.count: starts.append(i + 1)
                default: break
                }
            }
        }
        self.data = data
        self.rowStarts = starts
        self.rowCount = max(starts.count - 1, 0)
        self.header = starts.isEmpty ? [] : Self.parse(data, from: 0, to: starts.count > 1 ? starts[1] : data.count)
    }

    /// Fields of data row `row` (0-based, header excluded).
    func fields(at row: Int) -> [String] {
        let i = row + 1
        return Self.parse(data, from: rowStarts[i], to: i + 1 < rowStarts.count ? rowStarts[i + 1] : data.count)
    }

    private static func parse(_ data: Data, from start: Int, to end: Int) -> [String] {
        data.withUnsafeBytes { all in
            var line = all[start..<end]
            while let last = line.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") { line = line.dropLast() }

            var fields: [String] = []
            var field: [UInt8] = []
            var inQuotes = false
            var i = line.startIndex
            while i < line.endIndex {
                let b = line[i]
                if inQuotes {
                    if b == UInt8(ascii: "\"") {
                        if i + 1 < line.endIndex, line[i + 1] == UInt8(ascii: "\"") { field.append(b); i += 1 } else { inQuotes = false }
                    } else {
                        field.append(b)
                    }
                } else if b == UInt8(ascii: "\"") {
                    inQuotes = true
                } else if b == UInt8(ascii: ",") {
                    fields.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                } else {
                    field.append(b)
                }
                i += 1
            }
            fields.append(String(decoding: field, as: UTF8.self))
            return fields
        }
    }
}
