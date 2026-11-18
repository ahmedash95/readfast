import CReadFast
import Testing

/// The C SIMD primitives, each checked against a scalar version.
struct ScanTests {
    @Test func eqMaskSetsOneBitPerMatch() {
        var b = [UInt8](repeating: UInt8(ascii: " "), count: 64)
        b[2] = UInt8(ascii: ","); b[9] = UInt8(ascii: ","); b[63] = UInt8(ascii: ",")
        #expect(rf_eq_mask(b, UInt8(ascii: ",")) == UInt64(1) << 2 | UInt64(1) << 9 | UInt64(1) << 63)
        #expect(rf_eq_mask(b, UInt8(ascii: "\n")) == 0)
    }

    @Test func eqMaskMatchesScalarOnRandomBlocks() {
        var rng = SplitMix(state: 1)
        for _ in 0..<2000 {
            let b = randomBytes(64, &rng, alphabet: "\0\u{1},\n\"a")
            for c in [UInt8(ascii: ","), UInt8(ascii: "\n"), UInt8(ascii: "\""), 0] {
                var want: UInt64 = 0
                for i in 0..<64 where b[i] == c { want |= 1 << UInt64(i) }
                #expect(rf_eq_mask(b, c) == want)
            }
        }
    }

    @Test func prefixXor() {
        #expect(rf_prefix_xor(0) == 0)
        #expect(rf_prefix_xor(1) == ~0) // one quote at bit 0: inside for the rest
        #expect(rf_prefix_xor(0b1001000) == 0b0111000) // quotes at 3 and 6
    }

    @Test func countByteMatchesScalarIncludingTails() {
        var rng = SplitMix(state: 2)
        for n in 0..<300 {
            let d = randomBytes(n, &rng)
            #expect(rf_count_byte(d, d.count, UInt8(ascii: "\"")) == d.filter { $0 == UInt8(ascii: "\"") }.count)
        }
    }

    static let comma = UInt8(ascii: ","), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")

    @Test(arguments: [0, 1, 2] as [UInt8], [lf, cr])
    func findNewlineFindsEveryKth(start: UInt8, newline: UInt8) {
        var rng = SplitMix(state: 3)
        for n in 0..<300 {
            let d = randomBytes(n, &rng)
            let want = Oracle.newlines(d, start: start, newline: newline)
            for (k, pos) in want.enumerated() {
                #expect(rf_find_newline(d, d.count, start, Self.comma, newline, UInt64(k + 1)) == Int64(pos))
            }
            #expect(rf_find_newline(d, d.count, start, Self.comma, newline, UInt64(want.count + 1)) == -1)
            #expect(rf_find_newline(d, d.count, start, Self.comma, newline, 0) == -1)
        }
    }

    /// Per-block counts and start states must equal the scalar truth for any
    /// block size and thread count, including fields open across chunk splits
    /// (the chunks' guessed start states are wrong and get repaired).
    @Test(arguments: [64, 128, 192], [1, 2, 3, 8])
    func indexBlocksMatchOracle(blockSize: Int, threads: Int) {
        var rng = SplitMix(state: UInt64(blockSize * 31 + threads))
        for trial in 0..<300 {
            let start = UInt8(trial % 3) // continuing a segment that ended in any state
            let newline = trial % 4 == 3 ? Self.cr : Self.lf
            // mostly-quote inputs stress long quote runs and plain-quote rounds
            let alphabet = trial % 5 == 4 ? "\"\"\"a,\n" : "aab,,\n\n\"\r"
            let d = randomBytes(Int.random(in: 0..<1500, using: &rng), &rng, alphabet: alphabet)
            let blocks = (d.count + blockSize - 1) / blockSize
            var counts = [UInt32](repeating: 0, count: blocks)
            var states = [UInt8](repeating: 9, count: blocks)
            let end = rf_index(d, d.count, blockSize, threads, Self.comma, newline, start, &counts, &states)

            let want = Oracle.scan(d, start: start, newline: newline)
            for b in 0..<blocks {
                let r = (b * blockSize)..<min(d.count, (b + 1) * blockSize)
                #expect(states[b] == want.states[r.lowerBound], "block \(b) start state")
                #expect(Int(counts[b]) == want.newlines.filter { r.contains($0) }.count, "block \(b) count")
            }
            #expect(end == want.states[d.count])
        }
    }

    @Test func quotedNewlineStraddlingChunkBoundary() {
        // 2 chunks of one 64-byte block each; the quote opens in chunk 0 and closes in chunk 1
        var d = [UInt8](repeating: UInt8(ascii: "x"), count: 128)
        d[59] = Self.comma; d[60] = UInt8(ascii: "\""); d[66] = Self.lf; d[70] = UInt8(ascii: "\""); d[80] = Self.lf
        var counts = [UInt32](repeating: 0, count: 2), states = [UInt8](repeating: 0, count: 2)
        _ = rf_index(d, d.count, 64, 2, Self.comma, Self.lf, 0, &counts, &states)
        #expect(counts == [0, 1])
        #expect(states == [0, UInt8(RF_QUOTED)])
    }

    @Test func strayQuoteIsPlain() {
        // a quote after an ordinary byte doesn't open anything, in any block position
        for at in 1..<127 {
            var d = [UInt8](repeating: UInt8(ascii: "x"), count: 128)
            for i in stride(from: 9, to: 128, by: 10) { d[i] = Self.lf }
            if d[at] == Self.lf || d[at - 1] == Self.lf { continue }
            d[at] = UInt8(ascii: "\"")
            var counts = [UInt32](repeating: 0, count: 2), states = [UInt8](repeating: 0, count: 2)
            _ = rf_index(d, d.count, 64, 2, Self.comma, Self.lf, 0, &counts, &states)
            #expect(counts == [6, 6], "quote at \(at)")
        }
    }
}
