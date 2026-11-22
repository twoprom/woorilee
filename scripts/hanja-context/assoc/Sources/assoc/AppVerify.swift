// App-settings evaluation. Legacy d2-verify/eval5d remain unchanged for historical comparisons.
import Foundation

@MainActor
enum AppVerify {
    static func run(inputPath: String, outputPath: String) throws {
        let rows = try MinedRowLoader.load(path: inputPath)
        let table = Fixtures.associationTableFromBinary
        let biases = Fixtures.associationBiasFromBinary
        let lookup: (String, String) -> [String: Double]? = { table[$0]?[$1] }
        var output = ""
        var exactCount = 0
        var durations: [Double] = []
        var stageSamples: [String: [Double]] = [:]
        var rowTimings: [String: Double] = [:]
        var lookupCount = 0
        HanjaPerformance.observer = { stage, microseconds in
            stageSamples[stage, default: []].append(microseconds)
            rowTimings[stage, default: 0] += microseconds
            if stage == "dictionary_lookup" { lookupCount += 1 }
        }
        defer { HanjaPerformance.observer = nil }
        for row in rows {
            rowTimings = [:]
            lookupCount = 0
            let start = DispatchTime.now().uptimeNanoseconds
            let analysis = KiwiAnalysisService.analyzeClause(
                row.sentence, kiwi: Fixtures.kiwi, candidateLookup: Fixtures.candidateLookup,
                hangulUsageLookup: { _ in 0 }, dominantMap: Fixtures.dominantMap,
                associationFeatureLookup: lookup,
                associationBiasLookup: { biases[$0]?[$1] },
                autoConvertGate: Fixtures.autoConvertGate,
                nativeHomographLookup: Fixtures.nativeHomographLookup
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            durations.append(elapsed)
            let matches = analysis.segments.filter { $0.normalizedLookupKey == row.reading }
            let exact = matches.first { $0.sourceRange == NSRange(location: row.spanStart, length: row.spanLen) }
            if exact != nil { exactCount += 1 }
            var record: [String: Any] = [
                "id": row.id, "reading": row.reading, "split": row.split,
                "target_start": row.spanStart, "target_length": row.spanLen,
                "seg_ok": exact != nil, "analysis_ms": elapsed,
                "mode": "app", "top_n": KiwiAnalysisService.realtimeAnalysisCandidateCount,
                "personalization": "empty", "session": "empty",
                "label_provenance": "not_independently_reviewed",
                "stage_us": rowTimings, "dictionary_lookups": lookupCount
            ]
            // Keep a mismatching span for diagnosis, but never count it as a successful target.
            if let segment = exact ?? matches.first {
                let candidates = Fixtures.candidateLookup(segment.normalizedLookupKey)
                let ranked = rankSegmentCandidates(candidates, for: segment,
                    associationLookup: lookup, biasLookup: { biases[$0]?[$1] })
                let scores = associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: lookup)
                record["segment_start"] = segment.sourceRange.location
                record["segment_length"] = segment.sourceRange.length
                record["pos_tag"] = segment.tag.description
                record["panel_candidates"] = ranked.map { $0.candidate.value }
                record["auto_value"] = segment.previewCandidate?.value ?? ""
                record["hold_reason"] = holdReason(segment, candidates: candidates)
                record["scores"] = ranked.map { entry -> [String: Any] in
                    let candidate = entry.candidate
                    let evidence = contextEvidence(for: candidate,
                        contextDominantHanja: segment.contextDominantHanja,
                        associationScores: scores, weights: .default)
                    return ["value": candidate.value, "boost": entry.boost,
                            "dictionary": evidence.dictionaryBoost,
                            "association_raw": scores[candidate.value] ?? 0,
                            "bias_raw": biases[candidate.reading]?[candidate.value] ?? 0,
                            "gazette": segment.tag == .nnp && !candidate.comment.isEmpty
                                ? HanjaContextRankingWeights.default.nnpGazetteBonus * HanjaContextRankingWeights.default.association : 0,
                            "word_frequency": Fixtures.freqTable.wordFrequency(for: candidate.value),
                            "frequency": candidate.frequency, "base_rank": candidate.baseRank,
                            "word_evidence": Fixtures.autoConvertGate(candidate, segment.tag)]
                }
            } else {
                record["panel_candidates"] = [String]()
                record["auto_value"] = ""
                record["hold_reason"] = "segment_missing"
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            output += String(decoding: data, as: UTF8.self) + "\n"
        }
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        let sorted = durations.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        var stageReport: [String: Any] = [:]
        for (stage, values) in stageSamples {
            let sorted = values.sorted()
            func p(_ quantile: Double) -> Double { sorted[Int(Double(sorted.count - 1) * quantile)] }
            stageReport[stage] = ["samples": sorted.count, "p50_us": p(0.5), "p95_us": p(0.95), "p99_us": p(0.99)]
        }
        let timingData = try JSONSerialization.data(withJSONObject: stageReport, options: [.prettyPrinted, .sortedKeys])
        try timingData.write(to: URL(fileURLWithPath: outputPath + ".timing.json"))
        print("app-verify: rows=\(rows.count) exact=\(exactCount) p50=\(percentile(0.5))ms p95=\(percentile(0.95))ms p99=\(percentile(0.99))ms (analysis only, first row includes lazy warm-up)")
    }

    private static func holdReason(_ segment: HanjaSegment, candidates: [HanjaCandidate]) -> String {
        if segment.previewCandidate != nil { return "converted" }
        if candidates.isEmpty { return "dictionary_missing" }
        if NumericHanjaCandidateGenerator.normalizedDigits(from: segment.surface) != nil { return "numeric_manual_only" }
        if !KiwiAnalysisService.isRealtimeAutoConvertEligibleTag(segment.tag) { return "pos_manual_only" }
        if segment.awaitsContextEvidence { return "native_homograph_without_positive_evidence" }
        return "word_evidence_gate"
    }
}
