// Reproduces woorileeTests/HanjaContextEvalV2Tests.evaluate(rows:useAssociation:) EXACTLY, for the
// v1 195-row set, config=on (association table) and config=off (containment-only baseline).
//     Copyright (C) 2026 Seungjin Lee.
//
// This is the REAL production association-ranker pipeline (topN=1, matching KiwiAnalysisService's
// own "eval path" convention — NOT the runtime's topN=3 analyzeClauseDetailed): Kiwi analyze ->
// KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens -> .applyContextReranking -> panel
// order via rankWithContext + associationScores. Every one of those calls is real app source
// (symlinked); this file only loops rows and prints results, exactly mirroring the test's own
// `evaluate` function so the printed EVAL5D numbers can be diffed against the app's own test
// output line for line.
import Foundation
import Kiwi

struct Eval5DOutcome {
    var n = 0
    var top1 = 0
    var top3 = 0
    var segMiss = 0
    var segMissRows: [String] = []
    var flagshipRank: Int?
    var perSeries: [String: (n: Int, top1: Int)] = [:]
    var perRow: [(row: EvalRow, rank: Int?, predicted: String?)] = []
    var scored: Int { n - segMiss }
}

@MainActor
enum Eval5D {
    static func evaluate(rows: [EvalRow], useAssociation: Bool, associationTable: [String: [String: [String: Double]]],
                         biasTable: [String: [String: Double]] = [:]) -> Eval5DOutcome {
        var outcome = Eval5DOutcome()
        let kiwi = Fixtures.kiwi

        let associationLookup: ((String, String) -> [String: Double]?)? = useAssociation
            ? { reading, hanja in associationTable[reading]?[hanja] }
            : nil
        // D3: mirrors production (`KiwiAnalysisService.analyzeClauseDetailed` +
        // `HanjaServiceCoordinator.realtimeCandidates`), which both feed the store's bias into the
        // ranker. Without this the harness would score a θ-only model that no shipping code path
        // uses.
        let biasLookup: ((String, String) -> Double?)? = useAssociation
            ? { reading, hanja in biasTable[reading]?[hanja] }
            : nil

        for row in rows {
            outcome.n += 1

            guard let results = try? kiwi.analyze(row.sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions) else {
                outcome.segMiss += 1
                outcome.segMissRows.append("\(row.reading)/\(row.answer) :: \(row.sentence)")
                outcome.perRow.append((row: row, rank: nil, predicted: nil))
                continue
            }

            let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.sentence, candidateLookup: Fixtures.candidateLookup, hangulUsageLookup: { _ in 0 }
            )

            guard let segmentIndex = segments.firstIndex(where: { $0.normalizedLookupKey == row.reading }) else {
                outcome.segMiss += 1
                outcome.segMissRows.append("\(row.reading)/\(row.answer) :: \(row.sentence)")
                outcome.perRow.append((row: row, rank: nil, predicted: nil))
                continue
            }

            let reranked = KiwiAnalysisService.applyContextReranking(
                to: segments, clause: row.sentence, dominantMap: Fixtures.dominantMap,
                candidateLookup: Fixtures.candidateLookup, winningTokens: winningTokens,
                associationFeatureLookup: associationLookup,
                associationBiasLookup: biasLookup
            )
            let segment = reranked[segmentIndex]

            let candidates = Fixtures.candidateLookup(segment.normalizedLookupKey)
            let scores = associationLookup.map {
                associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: $0)
            } ?? [:]
            var biases: [String: Double] = [:]
            if let biasLookup {
                for candidate in candidates {
                    if let b = biasLookup(candidate.reading, candidate.value) { biases[candidate.value] = b }
                }
            }
            let rankedValues = rankWithContext(
                candidates: candidates, contextDominantHanja: segment.contextDominantHanja,
                associationScores: scores, weights: .default, biases: biases
            ).map(\.value)
            let rank = rankedValues.firstIndex(of: row.answer).map { $0 + 1 }
            outcome.perRow.append((row: row, rank: rank, predicted: rankedValues.first))

            if row.reading == "수도", row.sentence == "우리 집 수도가 얼었다." {
                outcome.flagshipRank = rank
            }

            var s = outcome.perSeries[row.reading] ?? (0, 0)
            s.n += 1
            if let r = rank {
                if r == 1 { outcome.top1 += 1; s.top1 += 1 }
                if r <= 3 { outcome.top3 += 1 }
            }
            outcome.perSeries[row.reading] = s
        }

        return outcome
    }

    static func run() throws {
        let v1 = try EvalSetLoader.loadV1()
        guard v1.count >= 195 else {
            print("EVAL5D|ERROR v1.count=\(v1.count) < 195")
            return
        }

        for (label, table) in [("txt", Fixtures.associationTableFromText), ("bin", Fixtures.associationTableFromBinary)] {
            print("EVAL5D|table=\(label) readings=\(table.count)")
            let biasTable = label == "bin" ? Fixtures.associationBiasFromBinary : [:]
            let off = evaluate(rows: v1, useAssociation: false, associationTable: table, biasTable: biasTable)
            let on = evaluate(rows: v1, useAssociation: true, associationTable: table, biasTable: biasTable)

            print("EVAL5D|table=\(label) config=off|v1 top1=\(off.top1)/\(off.scored) (\(pct(off.top1, off.scored))) top3=\(off.top3)/\(off.scored) segMiss=\(off.segMiss)")
            print("EVAL5D|table=\(label) config=on|v1 top1=\(on.top1)/\(on.scored) (\(pct(on.top1, on.scored))) top3=\(on.top3)/\(on.scored) segMiss=\(on.segMiss)")
            for miss in on.segMissRows { print("EVAL5D|table=\(label) segMiss v1 \(miss)") }
            for (row, rank, predicted) in on.perRow {
                print("EVAL5D_ROW|table=\(label) reading=\(row.reading) answer=\(row.answer) rank=\(rank.map(String.init) ?? "notFound") predicted=\(predicted ?? "n/a") :: \(row.sentence)")
            }
        }
    }
}
