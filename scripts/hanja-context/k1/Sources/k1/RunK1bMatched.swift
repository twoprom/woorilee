// K1b Part 1 — decisive test (matched-topN centering) + cheap test (31-reading eval-composition
// subset). Coordinator brief after the topN sweep surfaced a selection-effect concern: raising topN
// increased surfacing (55.7% -> 76.0%) but the RAW correct count stayed flat (1000 -> 1005 -> 1000)
// because the previous sweep centered topN=100/300 scores on topN=30-fitted baselines (a stated,
// deliberate confound at the time — "indicative, not a headline"). This run removes that confound by
// re-estimating baselines AT topN=300 for the slice's own (reading,candidate) pairs, then re-scoring
// the SAME slice with matched centering. Binary question: does K1 still beat the frequency floor once
// centering matches the analysis topN?
//
// Cost control (coordinator-specified): reuse the cached RAW occurrence list in
// baseline-occurrences.tsv (skip the ~16s corpus scan, but more importantly skip re-discovering which
// sentences even contain each reading), restricted to the slice's own readings (not all 3,025), and
// subsampled to a small cap per reading (10-15, not 40) — the dominant cost in the original run was
// KIWI VERIFICATION of each occurrence (1015.7s for 118,446 occurrences at topN=30), which scales with
// occurrence count x topN, so both restrictions matter.
//
// Second, cheap test: restrict holdout to the 258-row eval set's own 31 readings (derived from the
// eval TSV itself, not hardcoded) — reuses the ALREADY-COMPUTED topN=30 full-holdout scoring, zero new
// Kiwi calls.
import Foundation

func runK1bMatched(baselineStatsPath: String, occurrencesPath: String, capPerBucket: Int, occurrenceCapPerReading: Int) throws {
    print("=== k1b-matched (decisive matched-topN=300 test + 31-reading eval-composition subset) ===")
    let overallStart = Date()
    try ensureOutDir()

    let donorRows = try loadDonorsTable()
    var donorRowsByReading: [String: [DonorRow]] = [:]
    for row in donorRows { donorRowsByReading[row.reading, default: []].append(row) }
    let inventory = try TargetInventory.load()

    print("building aliased Kiwi (replaying \(donorRows.count) donor registrations, TargetInventory.allPairs order)...")
    let kiwi = try buildAliasedKiwiFromDonorsTable(donorRows, inventory: inventory)

    let baselines30URL = URL(fileURLWithPath: baselineStatsPath)
    print("loading cached topN=30 baselines from \(baselines30URL.path)...")
    let baselines30 = try loadBaselineStats(from: baselines30URL)
    print("  \(baselines30.count) pairs")

    let holdoutRows = try loadMeasureRows(Paths.measureDir.appendingPathComponent("holdout.tsv"))
    print("re-scoring \(holdoutRows.count) holdout rows at topN=30 (reproduces the exact slice + feeds the 31-reading test, zero new corpus scan)...")
    let baseStart = Date()
    let (holdoutScored30, _) = try scoreRows(holdoutRows, donorRowsByReading: donorRowsByReading, baselines: baselines30, inventory: inventory, kiwi: kiwi, topN: 30)
    let baseElapsed = Date().timeIntervalSince(baseStart)
    print(String(format: "  done in %.1fs", baseElapsed))

    // ================= reconstruct the EXACT same stratified slice as k1b-sweep =================
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
    print("reconstructed slice: \(sliceRows.count) rows (must match the sweep run's 3550)")

    // ================= TASK B (cheap) — 31-reading eval-composition subset =================
    print("Task B: 31-reading eval-composition subset (reusing topN=30 holdout scoring, no new Kiwi calls)...")
    let evalReadings = Set(try dataLines(of: Paths.evalTSV).compactMap { line -> String? in
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 3 else { return nil }
        return String(cols[1])
    })
    print("  \(evalReadings.count) distinct readings in the 258-row eval set: \(evalReadings.sorted().joined(separator: ","))")
    var eval31Group = SweepGroupStats()
    var restGroup = SweepGroupStats()
    for i in 0..<holdoutRows.count {
        let scored = holdoutScored30[i]
        guard scored.status == "scored" else { continue }
        var g = evalReadings.contains(holdoutRows[i].reading) ? eval31Group : restGroup
        g.n += 1
        if scored.goldSurfaced {
            g.goldSurfaced += 1
            if scored.correct { g.correctGivenSurfaced += 1 }
            if scored.floorACorrect { g.floorACorrectGivenSurfaced += 1 }
            g.floorBSumGivenSurfaced += scored.floorBExpected
        }
        if evalReadings.contains(holdoutRows[i].reading) { eval31Group = g } else { restGroup = g }
    }
    // unconditional correct/floorA/floorB need a separate full-group tally (not just the surfaced subset)
    var eval31Unconditional = (correct: 0, floorA: 0, floorBSum: 0.0, n: 0)
    var restUnconditional = (correct: 0, floorA: 0, floorBSum: 0.0, n: 0)
    for i in 0..<holdoutRows.count {
        let scored = holdoutScored30[i]
        guard scored.status == "scored" else { continue }
        let isEval = evalReadings.contains(holdoutRows[i].reading)
        var u = isEval ? eval31Unconditional : restUnconditional
        u.n += 1
        if scored.correct { u.correct += 1 }
        if scored.floorACorrect { u.floorA += 1 }
        u.floorBSum += scored.floorBExpected
        if isEval { eval31Unconditional = u } else { restUnconditional = u }
    }
    print(String(format: "  31-reading subset: n=%d, rest: n=%d", eval31Group.n, restGroup.n))

    // ================= TASK A (decisive) — matched-topN=300 baselines on the slice =================
    let sliceReadings = Set(sliceRows.map(\.reading))
    print("Task A: gathering cached occurrences for \(sliceReadings.count) slice readings (cap \(occurrenceCapPerReading)/reading) from \(occurrencesPath)...")
    let occStart = Date()
    let cachedOcc = try loadCachedOccurrences(from: URL(fileURLWithPath: occurrencesPath), onlyReadings: sliceReadings, capPerReading: occurrenceCapPerReading)
    let occLoadElapsed = Date().timeIntervalSince(occStart)
    let totalOccToVerify = cachedOcc.values.map(\.count).reduce(0, +)
    let readingsWithOcc = cachedOcc.count
    print(String(format: "  %d occurrences to verify across %d/%d slice readings (%.1fs to load/filter, no Kiwi yet)",
        totalOccToVerify, readingsWithOcc, sliceReadings.count, occLoadElapsed))

    // cost projection using the ALREADY-MEASURED topN=300 rate from the previous sweep run
    // (76.809 ms/row, k1b-sweep-report.md §2 cost table) — pure arithmetic, no new Kiwi calls needed
    // to produce this projection.
    let measuredMsPerRowAt300 = 76.809
    let projectedVerifySec = Double(totalOccToVerify) * measuredMsPerRowAt300 / 1000
    let projectedSliceRescoreSec = Double(sliceRows.count) * measuredMsPerRowAt300 / 1000
    print(String(format: "  PROJECTED cost: occurrence re-verification ~%.0fs + slice re-score at topN=300 ~%.0fs (measured directly below) = ~%.0fs total (~%.1f min)",
        projectedVerifySec, projectedSliceRescoreSec, projectedVerifySec + projectedSliceRescoreSec, (projectedVerifySec + projectedSliceRescoreSec) / 60))

    print("verifying occurrences + accumulating matched baselines at topN=300...")
    let verifyStart = Date()
    let (baselines300, verified, totalOcc) = try computeBaselines(
        occurrencesByReading: cachedOcc, orderedReadings: sliceReadings.sorted(),
        donorRowsByReading: donorRowsByReading, kiwi: kiwi, topN: 300)
    let verifyElapsed = Date().timeIntervalSince(verifyStart)
    print(String(format: "  %d/%d occurrences verified in %.1fs -> %d (reading,candidate) pairs have a matched topN=300 baseline",
        verified, totalOcc, verifyElapsed, baselines300.count))

    print("re-scoring the slice at topN=300 with MATCHED (topN=300) baselines...")
    let matchedScoreStart = Date()
    let (matchedScored, _) = try scoreRows(sliceRows, donorRowsByReading: donorRowsByReading, baselines: baselines300, inventory: inventory, kiwi: kiwi, topN: 300)
    let matchedScoreElapsed = Date().timeIntervalSince(matchedScoreStart)
    print(String(format: "  done in %.1fs", matchedScoreElapsed))

    // rows whose gold pair had NO matched-topN=300 baseline (status flips to noBaseline even if it
    // was "scored" under topN=30 baselines) are reported, not silently dropped.
    let matchedScoredOnly = matchedScored.filter { $0.status == "scored" }
    let droppedForNoMatchedBaseline = matchedScored.count - matchedScoredOnly.count
    print("  \(matchedScoredOnly.count)/\(matchedScored.count) slice rows retained a matched baseline (\(droppedForNoMatchedBaseline) dropped — gold pair had 0 verified occurrences at topN=300 in this capped subsample)")

    try writeK1bMatchedReport(
        sliceSize: sliceRows.count, occurrenceCapPerReading: occurrenceCapPerReading,
        sliceReadingsCount: sliceReadings.count, readingsWithOcc: readingsWithOcc, totalOccToVerify: totalOccToVerify,
        verified: verified, verifyElapsed: verifyElapsed, matchedScored: matchedScoredOnly, droppedForNoMatchedBaseline: droppedForNoMatchedBaseline,
        eval31Group: eval31Group, restGroup: restGroup,
        eval31Unconditional: eval31Unconditional, restUnconditional: restUnconditional,
        evalReadingsCount: evalReadings.count,
        totalElapsed: Date().timeIntervalSince(overallStart))
    print(String(format: "TOTAL wall time: %.1fs", Date().timeIntervalSince(overallStart)))
}
