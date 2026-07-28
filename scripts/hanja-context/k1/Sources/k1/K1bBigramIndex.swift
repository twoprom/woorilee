// Multi-pattern substring scanner for the K1b wiki baseline sample (docs/plans/
// hanja-context-scaling-plan.md §12 K1b-1 correction 1 — "기증자별 baseline을 위키 표본에서
// 오프라인으로 추정한다"). All ~3,000 target readings are 2+ Unicode scalars (targets.tsv:
// min_reading_length=2), so a 2-scalar-prefix hash bucket keeps each corpus position's candidate
// list small without needing a full Aho-Corasick automaton. Kiwi's own tokenization is the real
// arbiter of a true hit later (K1bBaseline.swift) — this scanner only proposes candidates.
//
// Positions are Unicode-SCALAR (codepoint) indices, matching extract_seeds.py's span_start/span_len
// ("Python character offsets" — Python 3 string indexing is codepoint-based) and, for the BMP-only
// Korean/Hanja content this corpus is made of, also matching Kiwi's chr_position (see collector's
// own "BMP CJK ranges only, so Character count == UTF-16 count" comment — for pure-BMP text scalar
// count / UTF-16 count / Character count all coincide).
import Foundation

struct BigramIndex {
    /// prefix key = (scalar0.value << 32) | scalar1.value
    private let buckets: [UInt64: [Int]]
    /// pattern index -> its scalar array, for the full-length compare after a bucket hit.
    let patternScalars: [[UInt32]]
    let patternStrings: [String]

    init(patterns: [String]) {
        var scalars: [[UInt32]] = []
        var strings: [String] = []
        var b: [UInt64: [Int]] = [:]
        for p in patterns {
            let sc = Array(p.unicodeScalars).map(\.value)
            guard sc.count >= 2 else { continue } // contract: every target reading is 2+ scalars
            let key = (UInt64(sc[0]) << 32) | UInt64(sc[1])
            b[key, default: []].append(scalars.count)
            scalars.append(sc)
            strings.append(p)
        }
        buckets = b
        patternScalars = scalars
        patternStrings = strings
    }

    /// Returns (patternIndex, scalarPosition) for every match in `text`, scanning once
    /// left-to-right. A position may match more than one pattern (rare, same 2-scalar prefix).
    func matches(in text: [UInt32]) -> [(patternIndex: Int, position: Int)] {
        guard text.count >= 2 else { return [] }
        var out: [(Int, Int)] = []
        for i in 0..<(text.count - 1) {
            let key = (UInt64(text[i]) << 32) | UInt64(text[i + 1])
            guard let bucket = buckets[key] else { continue }
            for pIdx in bucket {
                let pat = patternScalars[pIdx]
                guard i + pat.count <= text.count else { continue }
                var ok = true
                var k = 0
                while k < pat.count { if text[i + k] != pat[k] { ok = false; break }; k += 1 }
                if ok { out.append((pIdx, i)) }
            }
        }
        return out
    }
}
