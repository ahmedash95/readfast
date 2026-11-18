import Foundation
@testable import ReadFastCore

/// The spec, written the obvious way: a byte-by-byte state machine. Rows end
/// at `newline` outside a quoted field; a final newline doesn't start a row; a
/// trailing '\r' is dropped. A quote opens a quoted field only as a field's
/// first byte; inside one, "" is an escaped quote and a single quote closes it.
enum Oracle {
    enum State {
        case field, unquoted, quoted, closed

        /// readfast.h's state: right after a closing quote behaves like a field start.
        var c: UInt8 { switch self { case .field, .closed: 0; case .unquoted: 1; case .quoted: 2 } }
        init(_ c: UInt8) { self = [.field, .unquoted, .quoted][Int(c)] }
    }

    /// Row-ending newlines, and the state before each byte (plus one after the last).
    static func scan(_ d: [UInt8], start: UInt8 = 0, delimiter: UInt8 = UInt8(ascii: ","),
                     newline: UInt8 = UInt8(ascii: "\n")) -> (newlines: [Int], states: [UInt8]) {
        var s = State(start)
        var nl: [Int] = [], states: [UInt8] = []
        for (i, c) in d.enumerated() {
            states.append(s.c)
            switch s {
            case .quoted: if c == UInt8(ascii: "\"") { s = .closed }
            case .field, .unquoted, .closed:
                if c == newline { nl.append(i); s = .field }
                else if c == delimiter { s = .field }
                else if c == UInt8(ascii: "\""), s != .unquoted { s = .quoted }
                else { s = .unquoted }
            }
        }
        states.append(s.c)
        return (nl, states)
    }

    static func rowRanges(_ d: [UInt8], delimiter: UInt8 = UInt8(ascii: ","), newline: UInt8 = UInt8(ascii: "\n")) -> [Range<Int>] {
        guard !d.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var start = 0
        for i in scan(d, delimiter: delimiter, newline: newline).newlines {
            out.append(trim(start..<i, d))
            start = i + 1
        }
        if start < d.count { out.append(trim(start..<d.count, d)) }
        return out
    }

    /// Positions of row-ending newlines.
    static func newlines(_ d: [UInt8], start: UInt8 = 0, delimiter: UInt8 = UInt8(ascii: ","),
                         newline: UInt8 = UInt8(ascii: "\n")) -> [Int] {
        scan(d, start: start, delimiter: delimiter, newline: newline).newlines
    }

    private static func trim(_ r: Range<Int>, _ d: [UInt8]) -> Range<Int> {
        r.isEmpty || d[r.upperBound - 1] != UInt8(ascii: "\r") ? r : r.lowerBound..<(r.upperBound - 1)
    }
}

/// Random CSV-ish bytes from a small nasty alphabet: quotes, newlines, '\r', delimiters.
func randomBytes(_ n: Int, _ rng: inout some RandomNumberGenerator, alphabet: String = "aab,,\n\n\"\r") -> [UInt8] {
    let a = Array(alphabet.utf8)
    return (0..<n).map { _ in a[Int.random(in: 0..<a.count, using: &rng)] }
}

/// Deterministic generator so failures reproduce.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func tempFile(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-\(UUID().uuidString).csv")
    try Data(bytes).write(to: url)
    return url
}

func withBuffer<R>(_ d: [UInt8], _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try d.withUnsafeBytes(body)
}
