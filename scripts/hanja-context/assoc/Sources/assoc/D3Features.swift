// Step D3 offline feature extractor (docs/plans/hanja-context-scaling-plan.md §10, REDUCED SCOPE
// per the coordinator's 2026-08-01 scoping decision — see that plan section's header note): runs
// the REAL production context-aware Hanja ranking pipeline over the D1' seeds (seeds-v2,
// leak-filtered) so `scripts/hanja-context/build_d3_ranker.py` can train a signed sparse ranker
// against the EXACT same `HanjaSegment.contextFeatures` the runtime scores — no feature space is
// reimplemented here.
//     Copyright (C) 2026 Seungjin Lee.
//
// Pipeline (identical call sequence to ScoreHoldout.swift's `run`, "eval path" convention — no
// autoConvertGate/nativeHomographLookup, matching that file's own doc comment): for each row,
//   1. `kiwi.analyze(sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)`
//   2. `KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(...)`
//   3. segment identification: reuses ScoreHoldout.swift's OWN rule exactly — first prefer a
//      segment whose `sourceRange` OVERLAPS `[span_start, span_start+span_len)` AND whose
//      `normalizedLookupKey == reading` ("span" match); else fall back to the first segment whose
//      `normalizedLookupKey == reading` regardless of span ("name-fallback"); else no segment at
//      all matches the reading ("none"). `seg_ok` collapses this to the 1/0/segMiss contract this
//      task's output format specifies: span -> "1", name-fallback -> "0", none (or a Kiwi analyze
//      failure) -> "segMiss".
//   4. `KiwiAnalysisService.applyContextReranking(...)` (bin association table — passed as a
//      non-nil lookup purely so `HanjaSegment.contextFeatures` gets populated; this task does NOT
//      consume `applyContextReranking`'s association SCORES, only the feature list it computes for
//      the matched segment as a side effect of self-exclusion).
//   5. candidate ranking via `associationScores` + `rankWithContext(weights: .default)` — same call
//      shape as ScoreHoldout/Eval5D's own "eval path" reproduction — for `cand_count`/`sys_top1`.
// No ranking/segmentation/feature math is written here — every decision above is a call into
// symlinked app source (AppSource/) or Kiwi itself.
import Foundation
import Kiwi

struct D3SeedRow {
    let level: String
    let source: String
    let reading: String
    let hanja: String
    let pageID: String
    let family: String
    let spanStart: Int
    let spanLen: Int
    let inputSentence: String
}

enum D3SeedLoader {
    /// Column layout (seeds-v2, `seeds/part-*.tsv`'s own header comment):
    ///   level  source  reading  hanja  page_id  family  span_start  span_len  in_target_inventory
    ///   is_ambiguous  residual_hanja  input_sentence  evidence
    /// Only rows with level=="token", in_target_inventory=="1", and source NOT IN
    /// {redirect,title,dislink} are kept — this task's own filter (D3Features.swift §작업1).
    /// Streams `part-*.tsv` files in a directory (sorted by filename, matching the collector's own
    /// per-part convention) so a caller can point this at either the full seeds dir or a
    /// scratch dir holding a truncated smoke-test copy.
    static func loadFiltered(seedsDir: String) throws -> [D3SeedRow] {
        let fm = FileManager.default
        let partNames = try fm.contentsOfDirectory(atPath: seedsDir)
            .filter { $0.hasPrefix("part-") && $0.hasSuffix(".tsv") }
            .sorted()
        guard !partNames.isEmpty else {
            throw NSError(domain: "D3Features", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no part-*.tsv files found under \(seedsDir)",
            ])
        }

        let excludedSources: Set<String> = ["redirect", "title", "dislink"]
        var rows: [D3SeedRow] = []
        for name in partNames {
            let path = (seedsDir as NSString).appendingPathComponent(name)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if raw.hasPrefix("#") { continue }
                if raw.hasPrefix("level\t") { continue } // defensive: tolerate an accidental header row
                let c = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard c.count >= 13 else { continue }
                guard c[0] == "token" else { continue }
                guard !excludedSources.contains(c[1]) else { continue }
                guard c[8] == "1" else { continue } // in_target_inventory
                guard let spanStart = Int(c[6]), let spanLen = Int(c[7]) else { continue }
                rows.append(D3SeedRow(
                    level: c[0], source: c[1], reading: c[2], hanja: c[3], pageID: c[4], family: c[5],
                    spanStart: spanStart, spanLen: spanLen, inputSentence: c[11]
                ))
            }
        }
        return rows
    }
}

@MainActor
enum D3Features {
    static func run(seedsDir: String, outputPath: String) throws {
        let rows = try D3SeedLoader.loadFiltered(seedsDir: seedsDir)
        print("d3-features: loaded \(rows.count) filtered rows from \(seedsDir)")

        let table = Fixtures.associationTableFromBinary
        let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in table[reading]?[hanja] }
        // D3 (2026-08-01): `sys_top1` must reflect what production actually ranks, and production
        // feeds the store's candidate bias into the ranker. Without this the recorded prediction
        // would be a theta-only model no shipping path uses.
        let biasTable = Fixtures.associationBiasFromBinary
        let biasLookup: (String, String) -> Double? = { reading, hanja in biasTable[reading]?[hanja] }
        let kiwi = Fixtures.kiwi

        var out = "reading\tgold\tpage_id\tfamily\tsource\tseg_ok\tmatch_kind\tpos_tag\tcand_count\tsys_top1\tfeatures\n"

        var processed = 0
        var kiwiAnalyzeFailed = 0
        var spanMatched = 0
        var nameFallbackMatched = 0
        var segMissed = 0

        for row in rows {
            processed += 1
            if processed % 10_000 == 0 {
                print("d3-features: \(processed)/\(rows.count)")
            }

            guard let results = try? kiwi.analyze(row.inputSentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions) else {
                kiwiAnalyzeFailed += 1
                segMissed += 1
                out += "\(row.reading)\t\(row.hanja)\t\(row.pageID)\t\(row.family)\t\(row.source)\tsegMiss\tnone\t\t\t\t\n"
                continue
            }

            let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.inputSentence, candidateLookup: Fixtures.candidateLookup, hangulUsageLookup: { _ in 0 }
            )

            let targetSpan = NSRange(location: row.spanStart, length: row.spanLen)
            var matchKind = "none"
            var segmentIndex: Int?
            if let overlapIndex = segments.firstIndex(where: { rangesOverlapD3($0.sourceRange, targetSpan) && $0.normalizedLookupKey == row.reading }) {
                segmentIndex = overlapIndex
                matchKind = "span"
            } else if let nameIndex = segments.firstIndex(where: { $0.normalizedLookupKey == row.reading }) {
                segmentIndex = nameIndex
                matchKind = "name-fallback"
            }

            guard let segmentIndex else {
                segMissed += 1
                out += "\(row.reading)\t\(row.hanja)\t\(row.pageID)\t\(row.family)\t\(row.source)\tsegMiss\t\(matchKind)\t\t\t\t\n"
                continue
            }

            let segOk: String
            if matchKind == "span" {
                segOk = "1"
                spanMatched += 1
            } else {
                segOk = "0"
                nameFallbackMatched += 1
            }

            let reranked = KiwiAnalysisService.applyContextReranking(
                to: segments, clause: row.inputSentence, dominantMap: Fixtures.dominantMap,
                candidateLookup: Fixtures.candidateLookup, winningTokens: winningTokens,
                associationFeatureLookup: associationLookup,
                associationBiasLookup: biasLookup
            )
            let segment = reranked[segmentIndex]
            let candidates = Fixtures.candidateLookup(segment.normalizedLookupKey)
            let scores = associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: associationLookup)
            let rankedValues = rankWithContext(
                candidates: candidates, contextDominantHanja: segment.contextDominantHanja,
                associationScores: scores, weights: .default
            ).map(\.value)

            let posTag = "\(segment.tag)"
            let candCount = rankedValues.count
            let sysTop1 = rankedValues.first ?? ""
            let featuresField = segment.contextFeatures.joined(separator: "|")

            out += "\(row.reading)\t\(row.hanja)\t\(row.pageID)\t\(row.family)\t\(row.source)\t\(segOk)\t\(matchKind)\t\(posTag)\t\(candCount)\t\(sysTop1)\t\(featuresField)\n"
        }

        try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print(
            "d3-features: done. processed=\(processed) kiwiAnalyzeFailed=\(kiwiAnalyzeFailed) "
            + "span=\(spanMatched) nameFallback=\(nameFallbackMatched) segMiss=\(segMissed) -> \(outputPath)"
        )
    }

    private static func rangesOverlapD3(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }
}
