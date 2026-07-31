// Step D2 Task 3 (docs/plans/hanja-context-scaling-plan.md §9) — runs the REAL production
// context-aware Hanja ranking pipeline over build_d2_mining.py's mined sentences, so the D2 label
// sheet (Task 4) only has to ask a human to judge rows the system actually segmented correctly.
//     Copyright (C) 2026 Seungjin Lee.
//
// Pipeline (identical call sequence to ScoreHoldout.swift's `run`, extended with the two REAL
// production gate closures ScoreHoldout/Eval5D leave `nil` — see Fixtures.autoConvertGate /
// Fixtures.nativeHomographLookup): for each row,
//   1. `kiwi.analyze(sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)`
//   2. `KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(..., autoConvertGate:
//      Fixtures.autoConvertGate, nativeHomographLookup: Fixtures.nativeHomographLookup)`
//   3. `KiwiAnalysisService.applyContextReranking(...)` (bin association table)
//   4. candidate ranking via `associationScores` + `rankWithContext(weights: .default)` — same call
//      shape as ScoreHoldout/Eval5D's own "eval path" (no `segmentTag:`, matching the already-gated
//      reproduction of the app's EVAL_CTX/EVAL5D counts) — this produces `candidates`/`sys_top1`,
//      independent of the auto-convert gate.
// No ranking/segmentation math is written here — every decision above is a call into symlinked
// app source (AppSource/) or Kiwi itself.
import Foundation
import Kiwi

struct MinedRow {
    let id: String
    let reading: String
    let pageID: String
    let pageTitle: String
    let split: String
    let spanStart: Int
    let spanLen: Int
    let sentence: String
    let rawCols: [String]
}

enum MinedRowLoader {
    /// Column layout (build_d2_mining.py's `d2/mined-sentences.tsv`):
    ///   id  reading  page_id  page_title  split  span_start  span_len  sentence
    /// Lines starting with `#` (format header / stray comments) and blank lines are skipped.
    static func load(path: String) throws -> [MinedRow] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [MinedRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            if raw.hasPrefix("id\t") { continue } // defensive: tolerate an accidental header row
            let c = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 8, let spanStart = Int(c[5]), let spanLen = Int(c[6]) else { continue }
            rows.append(MinedRow(
                id: c[0], reading: c[1], pageID: c[2], pageTitle: c[3], split: c[4],
                spanStart: spanStart, spanLen: spanLen, sentence: c[7], rawCols: c
            ))
        }
        return rows
    }
}

@MainActor
enum D2Verify {
    static func run(inputPath: String, outputPath: String) throws {
        let rows = try MinedRowLoader.load(path: inputPath)
        let table = Fixtures.associationTableFromBinary
        print("d2-verify: loaded \(rows.count) rows from \(inputPath), assoc table readings=\(table.count)")

        let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in table[reading]?[hanja] }
        let kiwi = Fixtures.kiwi

        var out = "id\treading\tpage_id\tpage_title\tsplit\tspan_start\tspan_len\tsentence\t"
        out += "seg_ok\tpos_tag\tcand_count\tcandidates\tsys_top1\tauto_convert\n"

        var processed = 0
        var kiwiAnalyzeFailed = 0
        var segMissCount = 0
        var segMismatchCount = 0
        var segOkCount = 0

        for row in rows {
            processed += 1
            if processed % 2000 == 0 {
                print("d2-verify: \(processed)/\(rows.count)")
            }

            let inputCols = row.rawCols.joined(separator: "\t")

            guard let results = try? kiwi.analyze(row.sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions) else {
                kiwiAnalyzeFailed += 1
                segMissCount += 1
                out += "\(inputCols)\tsegMiss\t\t\t\t\t\n"
                continue
            }

            let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.sentence, candidateLookup: Fixtures.candidateLookup,
                hangulUsageLookup: { _ in 0 },
                autoConvertGate: Fixtures.autoConvertGate,
                nativeHomographLookup: Fixtures.nativeHomographLookup
            )

            let readingMatches = segments.enumerated().filter { $0.element.normalizedLookupKey == row.reading }
            guard !readingMatches.isEmpty else {
                segMissCount += 1
                out += "\(inputCols)\tsegMiss\t\t\t\t\t\n"
                continue
            }

            let exact = readingMatches.first { entry in
                entry.element.sourceRange.location == row.spanStart && entry.element.sourceRange.length == row.spanLen
            }
            let (segmentIndex, segOk): (Int, String)
            if let exact {
                segmentIndex = exact.offset
                segOk = "1"
                segOkCount += 1
            } else {
                segmentIndex = readingMatches[0].offset
                segOk = "0"
                segMismatchCount += 1
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

            let posTag = "\(segment.tag)"
            let candCount = rankedValues.count
            let candidatesField = rankedValues.prefix(10).joined(separator: ",")
            let sysTop1 = rankedValues.first ?? ""
            let autoConvert = segment.previewCandidate != nil ? "1" : "0"

            out += "\(inputCols)\t\(segOk)\t\(posTag)\t\(candCount)\t\(candidatesField)\t\(sysTop1)\t\(autoConvert)\n"
        }

        try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print(
            "d2-verify: done. processed=\(processed) kiwiAnalyzeFailed=\(kiwiAnalyzeFailed) "
            + "segOk=\(segOkCount) segMismatch=\(segMismatchCount) segMiss=\(segMissCount) -> \(outputPath)"
        )
    }
}
