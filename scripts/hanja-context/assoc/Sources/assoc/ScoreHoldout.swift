// Scores an arbitrary (reading, hanja, ..., span_start, span_len, input_sentence) TSV — the K1
// measure/holdout.tsv format — with the REAL production association-ranker pipeline, so its
// per-row predictions can be joined against K1's own per-row predictions for the K1b Part 2
// complementarity table.
//     Copyright (C) 2026 Seungjin Lee.
//
// Column layout (K1 package's `.../measure/{fit,holdout}.tsv`, header row prefixed `#`):
//   reading  hanja  sense_id  donor  donor_pos  source  family  page_id  span_start  span_len  input_sentence
//
// Segment identification: unlike the curated 195-row eval set (where `normalizedLookupKey ==
// reading` is unambiguous), a natural corpus sentence can contain the reading's surface more than
// once, or the Kiwi segmentation can tokenize the target span differently than expected. This
// picks the segment whose sourceRange OVERLAPS [span_start, span_start+span_len) (UTF-16 offsets,
// matching span_start/span_len's own units — see the K1b Task 1 report for how that was
// confirmed), falling back to the first segment matching `normalizedLookupKey == reading` only if
// no span-overlapping segment exists. Both outcomes are recorded (`match_kind` column) so a
// disagreement can be audited later instead of silently mixed in.
import Foundation
import Kiwi

struct HoldoutRow {
    let reading: String
    let hanja: String
    let senseID: String
    let donor: String
    let donorPos: String
    let source: String
    let family: String
    let pageID: String
    let spanStart: Int
    let spanLen: Int
    let sentence: String
    let rawLine: String
}

enum HoldoutLoader {
    static func load(path: String) throws -> [HoldoutRow] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [HoldoutRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            if raw.hasPrefix("reading\t") { continue } // header
            let c = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 11, let spanStart = Int(c[8]), let spanLen = Int(c[9]) else { continue }
            rows.append(HoldoutRow(
                reading: c[0], hanja: c[1], senseID: c[2], donor: c[3], donorPos: c[4],
                source: c[5], family: c[6], pageID: c[7], spanStart: spanStart, spanLen: spanLen,
                sentence: c[10], rawLine: String(raw)
            ))
        }
        return rows
    }
}

@MainActor
enum ScoreHoldout {
    static func run(inputPath: String, outputPath: String, useBinaryTable: Bool) throws {
        let rows = try HoldoutLoader.load(path: inputPath)
        let table = useBinaryTable ? Fixtures.associationTableFromBinary : Fixtures.associationTableFromText
        print("score-holdout: loaded \(rows.count) rows from \(inputPath), table=\(useBinaryTable ? "bin" : "txt") readings=\(table.count)")

        let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in table[reading]?[hanja] }

        var out = "reading\thanja\tsense_id\tdonor\tdonor_pos\tsource\tfamily\tpage_id\tspan_start\tspan_len\t"
        out += "match_kind\tsegment_found\tpredicted\trank\ttop1_correct\tcandidate_count\n"

        var processed = 0
        var segmentNotFound = 0
        var kiwiAnalyzeFailed = 0
        let kiwi = Fixtures.kiwi

        for row in rows {
            processed += 1
            if processed % 2000 == 0 {
                print("score-holdout: \(processed)/\(rows.count)")
            }

            guard let results = try? kiwi.analyze(row.sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions) else {
                kiwiAnalyzeFailed += 1
                out += "\(row.reading)\t\(row.hanja)\t\(row.senseID)\t\(row.donor)\t\(row.donorPos)\t\(row.source)\t\(row.family)\t\(row.pageID)\t\(row.spanStart)\t\(row.spanLen)\tnone\tfalse\t\t\t\t0\n"
                continue
            }

            let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.sentence, candidateLookup: Fixtures.candidateLookup, hangulUsageLookup: { _ in 0 }
            )

            let targetSpan = NSRange(location: row.spanStart, length: row.spanLen)
            var matchKind = "none"
            var segmentIndex: Int?
            if let overlapIndex = segments.firstIndex(where: { rangesOverlapLocal($0.sourceRange, targetSpan) && $0.normalizedLookupKey == row.reading }) {
                segmentIndex = overlapIndex
                matchKind = "span"
            } else if let nameIndex = segments.firstIndex(where: { $0.normalizedLookupKey == row.reading }) {
                segmentIndex = nameIndex
                matchKind = "name-fallback"
            }

            guard let segmentIndex else {
                segmentNotFound += 1
                out += "\(row.reading)\t\(row.hanja)\t\(row.senseID)\t\(row.donor)\t\(row.donorPos)\t\(row.source)\t\(row.family)\t\(row.pageID)\t\(row.spanStart)\t\(row.spanLen)\t\(matchKind)\tfalse\t\t\t\t0\n"
                continue
            }

            let reranked = KiwiAnalysisService.applyContextReranking(
                to: segments, clause: row.sentence, dominantMap: Fixtures.dominantMap,
                candidateLookup: Fixtures.candidateLookup, winningTokens: winningTokens,
                associationFeatureLookup: associationLookup
            )
            let segment = reranked[segmentIndex]
            let candidates = Fixtures.candidateLookup(segment.normalizedLookupKey)
            let scores = associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: associationLookup)
            let rankedValues = rankWithContext(
                candidates: candidates, contextDominantHanja: segment.contextDominantHanja,
                associationScores: scores, weights: .default
            ).map(\.value)
            let rank = rankedValues.firstIndex(of: row.hanja).map { $0 + 1 }
            let predicted = rankedValues.first ?? ""
            let top1Correct = (rank == 1)

            out += "\(row.reading)\t\(row.hanja)\t\(row.senseID)\t\(row.donor)\t\(row.donorPos)\t\(row.source)\t\(row.family)\t\(row.pageID)\t\(row.spanStart)\t\(row.spanLen)\t"
            out += "\(matchKind)\ttrue\t\(predicted)\t\(rank.map(String.init) ?? "")\t\(top1Correct)\t\(candidates.count)\n"
        }

        try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("score-holdout: done. processed=\(processed) kiwiAnalyzeFailed=\(kiwiAnalyzeFailed) segmentNotFound=\(segmentNotFound) -> \(outputPath)")
    }

    private static func rangesOverlapLocal(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }
}
