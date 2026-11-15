// Development-only segmentation comparison. Both arms reuse the production segment builder;
// no alternative is installed in the input method, and span coverage is not semantic accuracy.
import Foundation
import Kiwi

@MainActor
enum SegmentationCompare {
    static func run(inputPath: String, outputPath: String) throws {
        let rows = try MinedRowLoader.load(path: inputPath)
        var output = ""
        var currentExact = 0, scoreExact = 0
        var recovered: [String] = [], lost: [String] = [], changed: [String] = []
        var winnerCounts: [String: Int] = [:]
        for row in rows {
            let results = try Fixtures.kiwi.analyze(row.sentence,
                topN: KiwiAnalysisService.realtimeAnalysisCandidateCount,
                options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
            var cache: [String: [HanjaCandidate]] = [:]
            func candidates(_ key: String) -> [HanjaCandidate] {
                if let cached = cache[key] { return cached }
                let found = Fixtures.candidateLookup(key)
                cache[key] = found
                return found
            }
            let current = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.sentence, candidateLookup: candidates,
                autoConvertGate: Fixtures.autoConvertGate,
                nativeHomographLookup: Fixtures.nativeHomographLookup)
            // Preserve the first result on equal scores, matching the production tie convention.
            let scoreWinner = results.reduce(nil as TokenResult?) { best, candidate in
                guard let best else { return candidate }
                return candidate.score > best.score ? candidate : best
            }
            let scoreOnly = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: scoreWinner.map { [$0] } ?? [], in: row.sentence, candidateLookup: candidates,
                autoConvertGate: Fixtures.autoConvertGate,
                nativeHomographLookup: Fixtures.nativeHomographLookup)
            let range = NSRange(location: row.spanStart, length: row.spanLen)
            func target(_ segments: [HanjaSegment]) -> HanjaSegment? {
                segments.first { $0.sourceRange == range && $0.normalizedLookupKey == row.reading }
            }
            let currentTarget = target(current.segments), scoreTarget = target(scoreOnly.segments)
            currentExact += currentTarget == nil ? 0 : 1
            scoreExact += scoreTarget == nil ? 0 : 1
            if currentTarget == nil && scoreTarget != nil { recovered.append(row.id) }
            if currentTarget != nil && scoreTarget == nil { lost.append(row.id) }
            func signatures(_ tokens: [Token]) -> [String] {
                tokens.map { "\($0.position):\($0.length):\($0.form)/\($0.tag.description)" }
            }
            let currentWinner = results.firstIndex { signatures($0.tokens) == signatures(current.winningTokens) }
            winnerCounts[currentWinner.map(String.init) ?? "none", default: 0] += 1
            func spans(_ segments: [HanjaSegment]) -> [[String: Any]] {
                segments.map { ["start": $0.sourceRange.location, "length": $0.sourceRange.length,
                    "key": $0.normalizedLookupKey, "tag": $0.tag.description,
                    "convertible": $0.isConvertible] }
            }
            let currentSpans = spans(current.segments), alternativeSpans = spans(scoreOnly.segments)
            if !NSArray(array: currentSpans).isEqual(to: alternativeSpans) { changed.append(row.id) }
            let record: [String: Any] = ["id": row.id, "reading": row.reading, "split": row.split,
                "target_start": row.spanStart, "target_length": row.spanLen,
                "current_exact": currentTarget != nil, "score_first_exact": scoreTarget != nil,
                "current_analysis_index": currentWinner ?? -1,
                "analysis_scores": results.map(\.score),
                "current_spans": currentSpans, "score_first_spans": alternativeSpans]
            output += String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        let summary: [String: Any] = ["rows": rows.count, "current_exact": currentExact,
            "score_first_exact": scoreExact, "score_first_recovered": recovered,
            "score_first_lost": lost, "partition_changes": changed,
            "current_analysis_index_counts": winnerCounts,
            "decision": "Keep production policy. Exact-span coverage alone does not establish correct POS or meaning; independent compound/josa/proper-name labels are still required."]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outputPath + ".summary.json"))
        print("segmentation-compare: rows=\(rows.count) current_exact=\(currentExact) score_first_exact=\(scoreExact) changed_partitions=\(changed.count)")
    }
}
