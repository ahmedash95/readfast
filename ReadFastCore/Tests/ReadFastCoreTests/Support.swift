import Foundation
@testable import ReadFastCore

/// The spec, written the obvious way: rows end at '\n' outside quotes, a final
/// '\n' doesn't start a row, a trailing '\r' is dropped.
enum Oracle {
    static func rowRanges(_ d: [UInt8]) -> [Range<Int>] {
        guard !d.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var start = 0, inside = false
        for (i, c) in d.enumerated() {
            if c == UInt8(ascii: "\"") { inside.toggle() }
            if c == UInt8(ascii: "\n"), !inside {
                out.append(trim(start..<i, d))
                start = i + 1
            }
        }
        if start < d.count { out.append(trim(start..<d.count, d)) }
        return out
    }

    /// Positions of row-ending newlines.
    static func newlines(_ d: [UInt8], startInside: Bool = false) -> [Int] {
        var inside = startInside
        var out: [Int] = []
        for (i, c) in d.enumerated() {
            if c == UInt8(ascii: "\"") { inside.toggle() }
            if c == UInt8(ascii: "\n"), !inside { out.append(i) }
        }
        return out
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
