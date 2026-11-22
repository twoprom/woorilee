// Core scoring for K1b Part 1 (docs/plans/hanja-context-scaling-plan.md §12 K1b). Position-anchored
// per-sense parse probability, per-donor baseline centering, and the row-scoring pass shared by
// fit (threshold selection), holdout (reported accuracy), and the wiki baseline sample.
import Foundation

/// Like Replicate.swift's bestParseProbPerSense, but anchored to a specific scalar position when
/// one is known (row scoring, baseline-sample occurrences) — required once sentences can contain
/// the reading string more than once. `position == nil` falls back to form-only matching (used only
/// for the secondary 258-row eval set, which carries no span). K1a §7.3: the score is the WHOLE-PARSE
/// log-probability (kiwi_res_prob), never the token's own isolated score.
func bestParseProbAtPosition(_ results: [AnalysisResultRaw], form: String, position: Int?) -> [Int: Float] {
    var out: [Int: Float] = [:]
    for r in results {
        for tok in r.tokens where tok.form == form && (position == nil || tok.position == position!) {
            out[tok.senseId] = out[tok.senseId].map { Swift.max($0, r.prob) } ?? r.prob
        }
    }
    return out
}

struct BaselineStat {
    var sum: Double = 0
    var count: Int = 0
    var mean: Double { count > 0 ? sum / Double(count) : 0 }
}

/// One scored row's outcome — enough to both aggregate breakdowns and, if needed, dump a
/// per-row audit file.
struct ScoredRow {
    let reading: String
    let candidate: String
    let pageId: String
    let family: String
    let source: String
    let donor: String
    let candidateCount: Int
    let status: String // "scored" | "uncovered" | "noBaseline"
    let predicted: String? // nil only for status != "scored", or a scored row with zero surfacing
    let correct: Bool
    let noSurfaceMiss: Bool // true only for status=="scored" rows where no competitor's sense surfaced
    let goldSurfaced: Bool // did the GOLD candidate's own registered sense appear in topN at the target
    // position? Only meaningful when status=="scored" (false/unmeasured otherwise) — see
    // RunK1bDiagnose.swift: when gold doesn't surface, K1 cannot possibly predict it correctly, so
    // conflating "signal absent" with "signal invisible to topN" would misread the accuracy number.
    let floorAPredicted: String
    let floorACorrect: Bool
    let floorBExpected: Double
}

struct SurfaceCell {
    var surfaced = 0
    var total = 0
}

/// Scores one row list (fit OR holdout — same function, same finalized baselines, per the
/// non-transductivity requirement: baselines never come from the rows being scored here since
/// they were already finalized from the independent wiki sample in K1bBaseline.swift).
func scoreRows(
    _ rows: [MeasureRow],
    donorRowsByReading: [String: [DonorRow]],
    baselines: [PairKey: BaselineStat],
    inventory: TargetInventory,
    kiwi: KiwiRaw,
    topN: Int32
) throws -> (scored: [ScoredRow], surfaceByBucket: [String: SurfaceCell]) {
    var out: [ScoredRow] = []
    out.reserveCapacity(rows.count)
    var surfaceByBucket: [String: SurfaceCell] = [:]

    for row in rows {
        let totalCandidateCount = inventory.candidatesByReading[row.reading]?.count ?? 1
        let bucket = candidateCountBucket(totalCandidateCount)
        let floorAPredicted = inventory.candidatesByReading[row.reading]?.first ?? row.candidate
        let floorBExpected = 1.0 / Double(max(totalCandidateCount, 1))

        let covered = donorRowsByReading[row.reading] ?? []
        let goldKey = PairKey(reading: row.reading, candidate: row.candidate)
        let goldCovered = covered.contains { $0.candidate == row.candidate }

        guard goldCovered else {
            out.append(ScoredRow(
                reading: row.reading, candidate: row.candidate, pageId: row.pageId, family: row.family,
                source: row.source, donor: row.donor, candidateCount: totalCandidateCount, status: "uncovered",
                predicted: nil, correct: false, noSurfaceMiss: false, goldSurfaced: false,
                floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.candidate, floorBExpected: floorBExpected))
            continue
        }
        guard let goldBaseline = baselines[goldKey], goldBaseline.count > 0 else {
            out.append(ScoredRow(
                reading: row.reading, candidate: row.candidate, pageId: row.pageId, family: row.family,
                source: row.source, donor: row.donor, candidateCount: totalCandidateCount, status: "noBaseline",
                predicted: nil, correct: false, noSurfaceMiss: false, goldSurfaced: false,
                floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.candidate, floorBExpected: floorBExpected))
            continue
        }

        let results = try kiwi.analyze(row.inputSentence, topN: topN, matchOptionsRaw: Contract.matchOptionsRaw)
        let perSense = bestParseProbAtPosition(results, form: row.reading, position: row.spanStart)
        let goldSenseId = covered.first(where: { $0.candidate == row.candidate })!.senseId
        let goldSurfaced = perSense[goldSenseId] != nil

        // Surfacing cells: every donor-covered candidate of this reading, regardless of whether it
        // has a usable baseline — surfacing is about whether Kiwi's topN list contains the sense at
        // all, a property of the parse, not of our baseline bookkeeping.
        for c in covered {
            var cell = surfaceByBucket[bucket] ?? SurfaceCell()
            cell.total += 1
            if perSense[c.senseId] != nil { cell.surfaced += 1 }
            surfaceByBucket[bucket] = cell
        }

        // Competitor set for prediction: donor-covered AND baseline-known (centerable) candidates.
        var bestCandidate: String?
        var bestSignal = -Double.infinity
        var anySurfaced = false
        for c in covered.sorted(by: { $0.senseId < $1.senseId }) { // deterministic tie-break: lowest sense_id first
            guard let stat = baselines[PairKey(reading: row.reading, candidate: c.candidate)], stat.count > 0 else { continue }
            guard let score = perSense[c.senseId] else { continue }
            anySurfaced = true
            let signal = Double(score) - stat.mean
            if signal > bestSignal {
                bestSignal = signal
                bestCandidate = c.candidate
            }
        }

        out.append(ScoredRow(
            reading: row.reading, candidate: row.candidate, pageId: row.pageId, family: row.family,
            source: row.source, donor: row.donor, candidateCount: totalCandidateCount, status: "scored",
            predicted: bestCandidate, correct: (bestCandidate == row.candidate), noSurfaceMiss: !anySurfaced,
            goldSurfaced: goldSurfaced,
            floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.candidate, floorBExpected: floorBExpected))
    }
    return (out, surfaceByBucket)
}

/// Same scoring logic as `scoreRows`, adapted for the 258-row eval TSV (sentence, reading, gold —
/// no span/family/page_id, so position:nil / form-only matching, matching the original K1a
/// Replicate.swift convention for sentences without a known span).
func scoreEvalRows(
    _ rows: [(sentence: String, reading: String, gold: String)],
    donorRowsByReading: [String: [DonorRow]],
    baselines: [PairKey: BaselineStat],
    inventory: TargetInventory,
    kiwi: KiwiRaw,
    topN: Int32
) throws -> [ScoredRow] {
    var out: [ScoredRow] = []
    for row in rows {
        let totalCandidateCount = inventory.candidatesByReading[row.reading]?.count ?? 1
        let floorAPredicted = inventory.candidatesByReading[row.reading]?.first ?? row.gold
        let floorBExpected = 1.0 / Double(max(totalCandidateCount, 1))
        let covered = donorRowsByReading[row.reading] ?? []
        guard let goldInfo = covered.first(where: { $0.candidate == row.gold }) else {
            out.append(ScoredRow(
                reading: row.reading, candidate: row.gold, pageId: "", family: "", source: "", donor: "",
                candidateCount: totalCandidateCount, status: "uncovered", predicted: nil, correct: false,
                noSurfaceMiss: false, goldSurfaced: false,
                floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.gold, floorBExpected: floorBExpected))
            continue
        }
        let goldKey = PairKey(reading: row.reading, candidate: row.gold)
        guard let goldBaseline = baselines[goldKey], goldBaseline.count > 0 else {
            out.append(ScoredRow(
                reading: row.reading, candidate: row.gold, pageId: "", family: "", source: goldInfo.source, donor: goldInfo.donor,
                candidateCount: totalCandidateCount, status: "noBaseline", predicted: nil, correct: false,
                noSurfaceMiss: false, goldSurfaced: false,
                floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.gold, floorBExpected: floorBExpected))
            continue
        }
        let results = try kiwi.analyze(row.sentence, topN: topN, matchOptionsRaw: Contract.matchOptionsRaw)
        let perSense = bestParseProbAtPosition(results, form: row.reading, position: nil)
        let goldSurfaced = perSense[goldInfo.senseId] != nil
        var bestCandidate: String?
        var bestSignal = -Double.infinity
        var anySurfaced = false
        for c in covered.sorted(by: { $0.senseId < $1.senseId }) {
            guard let stat = baselines[PairKey(reading: row.reading, candidate: c.candidate)], stat.count > 0 else { continue }
            guard let score = perSense[c.senseId] else { continue }
            anySurfaced = true
            let signal = Double(score) - stat.mean
            if signal > bestSignal { bestSignal = signal; bestCandidate = c.candidate }
        }
        out.append(ScoredRow(
            reading: row.reading, candidate: row.gold, pageId: "", family: "", source: goldInfo.source, donor: goldInfo.donor,
            candidateCount: totalCandidateCount, status: "scored", predicted: bestCandidate,
            correct: (bestCandidate == row.gold), noSurfaceMiss: !anySurfaced, goldSurfaced: goldSurfaced,
            floorAPredicted: floorAPredicted, floorACorrect: floorAPredicted == row.gold, floorBExpected: floorBExpected))
    }
    return out
}
