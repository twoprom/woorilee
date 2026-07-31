// K1b Part 1 follow-up — two measurements in one run (coordinator brief after the gold_surfaced
// decomposition):
//   Task 1 — topN sweep (30/100/300) on a candidate-count-stratified holdout slice: how much of the
//     44.3% "gold never surfaces" gap is recoverable by enumeration alone (raising topN), which is
//     a free offline-teacher lever vs. the unverified `pretokenized` API workaround (§12 K1c).
//   Task 2 — definitional-sentence subset: Part 1's 258-eval conditional (12.3%) is far below
//     holdout's (43.2%) even though the eval set surfaces MORE (70.8% vs 55.7%), so surfacing alone
//     doesn't explain the gap. Hypothesis: D1 seeds are dominated by 병기-derived DEFINITIONAL
//     sentences (term at/near sentence start, ends in a copula/definition predicate), which are
//     easier than natural usage. Split holdout by a conservative heuristic and compare.
//
// Reuses baseline-stats.tsv (topN=30, from the completed run) — does NOT re-scan the corpus. Only
// re-scores holdout once at topN=30 (to get a fresh in-memory, index-aligned ScoredRow list to zip
// against MeasureRow for the definitional split) plus a candidate-count-stratified SLICE at
// topN=100/300 (not all 23,986 rows) — nowhere near the ~17-minute full pass.
import Foundation

let definitionalEndingSuffixes = ["이다", "이었다", "였다", "말한다", "뜻한다"]
let trailingPunctuationForDefinitional: Set<Character> = [".", "!", "?", "\"", "'", "」", "』", ")", "〉", "》", "\u{201D}", "\u{2019}"]

/// Conservative heuristic (coordinator's spec): the target span sits at/near sentence start AND the
/// sentence ends in a 이다/이었다/말한다/뜻한다-type predicate. `nearStartThreshold` in scalar/character
/// offset units (same convention as MeasureRow.spanStart — see extract_seeds.py span_start doc).
func isDefinitional(sentence: String, spanStart: Int, nearStartThreshold: Int = 5) -> Bool {
    guard spanStart <= nearStartThreshold else { return false }
    var s = Substring(sentence)
    while let last = s.last, last == " " || trailingPunctuationForDefinitional.contains(last) {
        s.removeLast()
    }
    return definitionalEndingSuffixes.contains { s.hasSuffix($0) }
}

func markedSentence(_ sentence: String, spanStart: Int, spanLen: Int) -> String {
    let scalars = Array(sentence.unicodeScalars)
    guard spanStart >= 0, spanStart + spanLen <= scalars.count else { return sentence }
    var out = String.UnicodeScalarView(scalars[0..<spanStart])
    out.append(contentsOf: "⟦".unicodeScalars)
    out.append(contentsOf: scalars[spanStart..<(spanStart + spanLen)])
    out.append(contentsOf: "⟧".unicodeScalars)
    out.append(contentsOf: scalars[(spanStart + spanLen)...])
    return String(out)
}

struct SweepGroupStats {
    var n = 0
    var goldSurfaced = 0
    var correctGivenSurfaced = 0
    var floorACorrectGivenSurfaced = 0
    var floorBSumGivenSurfaced = 0.0
}

func runK1bSweep(baselineStatsPath: String, capPerBucket: Int, probeSize: Int) throws {
    print("=== k1b-sweep (Task 1: topN sweep, Task 2: definitional-subset split) ===")
    let overallStart = Date()
    try ensureOutDir()

    let donorRows = try loadDonorsTable()
    var donorRowsByReading: [String: [DonorRow]] = [:]
    for row in donorRows { donorRowsByReading[row.reading, default: []].append(row) }
    let inventory = try TargetInventory.load()

    print("building aliased Kiwi (replaying \(donorRows.count) donor registrations, TargetInventory.allPairs order)...")
    let kiwi = try buildAliasedKiwiFromDonorsTable(donorRows, inventory: inventory)

    let baselineURL = URL(fileURLWithPath: baselineStatsPath)
    print("loading cached baselines (topN=30) from \(baselineURL.path) (NOT re-scanning the corpus)...")
    let baselines = try loadBaselineStats(from: baselineURL)
    print("  \(baselines.count) (reading,candidate) pairs have a cached baseline")

    let holdoutRows = try loadMeasureRows(Paths.measureDir.appendingPathComponent("holdout.tsv"))
    print("re-scoring \(holdoutRows.count) holdout rows at topN=30 (fresh in-memory, index-aligned with MeasureRow — needed to join sentence/span for the definitional split)...")
    let baseStart = Date()
    let (holdoutScored30, _) = try scoreRows(holdoutRows, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: 30)
    let baseElapsed = Date().timeIntervalSince(baseStart)
    print(String(format: "  done in %.1fs (%.2fms/row) — NOT the 17-minute full pass, corpus scan/baseline collection skipped", baseElapsed, baseElapsed / Double(holdoutRows.count) * 1000))

    // ================= TASK 2 — definitional-sentence subset =================
    print("Task 2: classifying definitional vs non-definitional (heuristic: span at/near sentence start AND ends in 이다/이었다/였다/말한다/뜻한다)...")
    var defGroup = SweepGroupStats()
    var nonDefGroup = SweepGroupStats()
    var definitionalFlaggedIdx: [Int] = []
    var nonDefinitionalFlaggedIdx: [Int] = []
    for i in 0..<holdoutRows.count {
        let scored = holdoutScored30[i]
        guard scored.status == "scored" else { continue }
        let row = holdoutRows[i]
        let flagged = isDefinitional(sentence: row.inputSentence, spanStart: row.spanStart)
        if flagged { definitionalFlaggedIdx.append(i) } else { nonDefinitionalFlaggedIdx.append(i) }
        var g = flagged ? defGroup : nonDefGroup
        g.n += 1
        if scored.goldSurfaced {
            g.goldSurfaced += 1
            if scored.correct { g.correctGivenSurfaced += 1 }
            if scored.floorACorrect { g.floorACorrectGivenSurfaced += 1 }
            g.floorBSumGivenSurfaced += scored.floorBExpected
        }
        if flagged { defGroup = g } else { nonDefGroup = g }
    }
    print(String(format: "  definitional=%d (%.1f%% of scored) non-definitional=%d", defGroup.n,
        Double(defGroup.n) / Double(defGroup.n + nonDefGroup.n) * 100, nonDefGroup.n))

    // hand-check manifest: first 40 flagged-definitional + first 20 flagged-non-definitional, in
    // file order (deterministic) — read and graded by the agent, not simulated.
    let handCheckWriter = try LineWriterK1(url: Paths.outDir.appendingPathComponent("definitional-handcheck-sample.tsv"))
    handCheckWriter.write("# definitional-handcheck-sample.tsv — first 40 flagged-definitional + first 20 flagged-non-definitional holdout rows, file order")
    handCheckWriter.write("# flag\treading\tcandidate\tspan_start\tmarked_sentence")
    for i in definitionalFlaggedIdx.prefix(40) {
        let row = holdoutRows[i]
        handCheckWriter.write(["definitional", row.reading, row.candidate, String(row.spanStart),
            markedSentence(row.inputSentence, spanStart: row.spanStart, spanLen: row.spanLen)].map(tsvEscape).joined(separator: "\t"))
    }
    for i in nonDefinitionalFlaggedIdx.prefix(20) {
        let row = holdoutRows[i]
        handCheckWriter.write(["non_definitional", row.reading, row.candidate, String(row.spanStart),
            markedSentence(row.inputSentence, spanStart: row.spanStart, spanLen: row.spanLen)].map(tsvEscape).joined(separator: "\t"))
    }
    handCheckWriter.close()
    print("  wrote definitional-handcheck-sample.tsv (60 rows) for hand-check")

    // ================= TASK 1 — topN sweep on a stratified slice =================
    print("Task 1: building candidate-count-stratified slice (cap \(capPerBucket)/bucket)...")
    var byBucket: [String: [Int]] = [:]
    for i in 0..<holdoutRows.count where holdoutScored30[i].status == "scored" {
        byBucket[candidateCountBucket(holdoutScored30[i].candidateCount), default: []].append(i)
    }
    var sliceIdx: [Int] = []
    for bucket in candidateCountBucketOrder {
        guard let idxs = byBucket[bucket] else { continue }
        sliceIdx.append(contentsOf: idxs.prefix(capPerBucket))
    }
    sliceIdx.sort()
    let sliceRows = sliceIdx.map { holdoutRows[$0] }
    print("  slice size: \(sliceRows.count) rows "
        + "(\(candidateCountBucketOrder.map { "\($0)=\(min(byBucket[$0]?.count ?? 0, capPerBucket))" }.joined(separator: ", ")))")

    // throughput probe before the full slice at each higher topN (report projected cost first)
    let probeRows = Array(sliceRows.prefix(probeSize))
    var msPerRowByTopN: [Int32: Double] = [30: baseElapsed / Double(holdoutRows.count) * 1000]
    for topN: Int32 in [100, 300] {
        let probeStart = Date()
        _ = try scoreRows(probeRows, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: topN)
        let probeElapsed = Date().timeIntervalSince(probeStart)
        let msPerRow = probeElapsed / Double(probeRows.count) * 1000
        let projected = msPerRow * Double(sliceRows.count) / 1000
        print(String(format: "  topN=%d probe: %d rows in %.2fs = %.3fms/row -> projected full slice (%d rows): %.1fs",
            topN, probeRows.count, probeElapsed, msPerRow, sliceRows.count, projected))
    }

    var scoredByTopN: [Int32: [ScoredRow]] = [30: sliceIdx.map { holdoutScored30[$0] }]
    for topN: Int32 in [100, 300] {
        print("  scoring full slice at topN=\(topN)...")
        let start = Date()
        let (scored, _) = try scoreRows(sliceRows, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: topN)
        let elapsed = Date().timeIntervalSince(start)
        let msPerRow = elapsed / Double(sliceRows.count) * 1000
        msPerRowByTopN[topN] = msPerRow
        scoredByTopN[topN] = scored
        print(String(format: "    done in %.1fs (%.3fms/row)", elapsed, msPerRow))
    }

    // per-bucket, per-topN gold_surfaced + indicative-correct rate on the slice
    var sweepTable: [String: [Int32: (n: Int, surfaced: Int, correct: Int)]] = [:]
    for topN: Int32 in [30, 100, 300] {
        guard let scored = scoredByTopN[topN] else { continue }
        for r in scored {
            let bucket = candidateCountBucket(r.candidateCount)
            var e = sweepTable[bucket]?[topN] ?? (0, 0, 0)
            e.n += 1
            if r.goldSurfaced { e.surfaced += 1 }
            if r.correct { e.correct += 1 }
            sweepTable[bucket, default: [:]][topN] = e
        }
    }
    // overall (unweighted across the slice as constructed — NOT a population-representative average, see report note)
    var overallByTopN: [Int32: (n: Int, surfaced: Int, correct: Int)] = [:]
    for topN: Int32 in [30, 100, 300] {
        guard let scored = scoredByTopN[topN] else { continue }
        overallByTopN[topN] = (scored.count, scored.filter(\.goldSurfaced).count, scored.filter(\.correct).count)
    }

    try writeK1bSweepReport(
        holdoutTotalScored: holdoutScored30.filter { $0.status == "scored" }.count,
        defGroup: defGroup, nonDefGroup: nonDefGroup,
        sliceSize: sliceRows.count, capPerBucket: capPerBucket,
        sweepTable: sweepTable, overallByTopN: overallByTopN, msPerRowByTopN: msPerRowByTopN,
        baseElapsed: baseElapsed, totalElapsed: Date().timeIntervalSince(overallStart))
    print(String(format: "TOTAL wall time: %.1fs", Date().timeIntervalSince(overallStart)))
}
