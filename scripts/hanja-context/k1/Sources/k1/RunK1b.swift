// K1b Part 1 — non-transductive per-donor baseline + coverage-bracket narrowing
// (docs/plans/hanja-context-scaling-plan.md §12 K1b). Orchestrates:
//   1. replay donors.tsv's registrations into one aliased Kiwi (K1bTables.swift)
//   2. load the coordinator-built measure/{fit,holdout}.tsv (already leak-filtered,
//      family-disjoint-split, donor-restricted — see docs/plans/hanja-context-d1-report.md §10.2
//      for the leak defect these files were built to exclude)
//   3. estimate a per-(reading,candidate) baseline from an INDEPENDENT wiki sample (filtered
//      corpus), excluding holdout page_ids and any line literally containing the candidate's own
//      hanja (leak-analog guard) — NOT from fit-split gold rows (that left 23% of holdout's pairs
//      unbaselined; see K1bBaseline.swift header)
//   4. score fit rows (threshold-selection sanity) and holdout rows (reported accuracy) with the
//      SAME finalized baselines
//   5. report sense-surfacing rate, coverage-bracket breakdown, floor baselines, and a direction-only
//      258-eval cross-check
import Foundation

struct K1bOptions {
    var capPerReading = 40
    var topN: Int32 = 30
    var throughputOnly = false
    var sweepCapPerBucket = 700
}

func fileSizeBytes(_ url: URL) -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
    return (attrs[.size] as? Int) ?? 0
}

struct Tally {
    var correct = 0
    var total = 0
    var pct: Double { total > 0 ? Double(correct) / Double(total) * 100 : 0 }
}

func writeEvalScoredTSV(_ rows: [ScoredRow]) throws {
    let writer = try LineWriterK1(url: Paths.outDir.appendingPathComponent("eval258-scored.tsv"))
    writer.write("# eval258-scored.tsv — per-row K1b scoring outcome on eval/hanja-context-eval-set.tsv (direction-only, 계획 §13 — never used for selection)")
    writer.write("# reading\tcandidate\tstatus\tpredicted\tcorrect\tno_surface_miss\tgold_surfaced\tfloorA_predicted\tfloorA_correct\tfloorB_expected\tsource\tdonor\tcandidate_count")
    for r in rows {
        writer.write([
            r.reading, r.candidate, r.status, r.predicted ?? "", String(r.correct), String(r.noSurfaceMiss), String(r.goldSurfaced),
            r.floorAPredicted, String(r.floorACorrect), String(format: "%.6f", r.floorBExpected),
            r.source, r.donor, String(r.candidateCount),
        ].map(tsvEscape).joined(separator: "\t"))
    }
    writer.close()
}

func tallyBy(_ rows: [ScoredRow], key: (ScoredRow) -> String) -> [String: Tally] {
    var out: [String: Tally] = [:]
    for r in rows {
        var t = out[key(r)] ?? Tally()
        t.total += 1
        if r.correct { t.correct += 1 }
        out[key(r)] = t
    }
    return out
}

func runK1b(_ options: K1bOptions) throws {
    print("=== k1b (Part 1: non-transductive donor baseline + coverage-bracket narrowing) ===")
    print("options: capPerReading=\(options.capPerReading) topN=\(options.topN) throughputOnly=\(options.throughputOnly)")
    try ensureOutDir()

    print("loading donors.tsv (will replay its registrations verbatim)...")
    let donorRows = try loadDonorsTable()
    var donorRowsByReading: [String: [DonorRow]] = [:]
    var donorInfoByPair: [PairKey: DonorRow] = [:]
    var donorReuseCount: [String: Int] = [:]
    for row in donorRows {
        donorRowsByReading[row.reading, default: []].append(row)
        donorInfoByPair[PairKey(reading: row.reading, candidate: row.candidate)] = row
        donorReuseCount[row.donor, default: 0] += 1
    }
    let ubiquitousDonors = Set(donorReuseCount.filter { $0.value >= 11 }.keys)
    print("  \(donorRows.count) donor rows / \(donorRowsByReading.count) readings / "
        + "\(ubiquitousDonors.count) donor strings reused >=11 pairs (final-rows proxy for K1a's pool-based ubiquity — see report caveat)")

    print("loading target inventory (candidate counts, freq-rank-1 floor baseline)...")
    let inventory = try TargetInventory.load()

    print("loading measure/fit.tsv and measure/holdout.tsv (coordinator-built — not rebuilt here)...")
    let fitRows = try loadMeasureRows(Paths.measureDir.appendingPathComponent("fit.tsv"))
    let holdoutRows = try loadMeasureRows(Paths.measureDir.appendingPathComponent("holdout.tsv"))
    print("  fit=\(fitRows.count) rows, holdout=\(holdoutRows.count) rows")

    let fitFamilies = Set(fitRows.map(\.family))
    let holdoutFamilies = Set(holdoutRows.map(\.family))
    let familyOverlap = fitFamilies.intersection(holdoutFamilies)
    print("  family-disjointness check: fit=\(fitFamilies.count) families, holdout=\(holdoutFamilies.count) families, "
        + "overlap=\(familyOverlap.count) (must be 0)")
    guard familyOverlap.isEmpty else {
        fail("family split is NOT disjoint — \(familyOverlap.count) families appear in both fit and holdout: "
            + familyOverlap.prefix(5).joined(separator: ", "))
    }

    var joinMismatches = 0
    for row in fitRows + holdoutRows {
        guard let d = donorInfoByPair[PairKey(reading: row.reading, candidate: row.candidate)] else { joinMismatches += 1; continue }
        if d.senseId != row.senseId || d.donor != row.donor || d.donorPos != row.donorPos || d.source != row.source { joinMismatches += 1 }
    }
    print("  join sanity vs donors.tsv: \(joinMismatches) mismatches / \(fitRows.count + holdoutRows.count) rows (expect 0)")

    let readingsOfInterest = Array(Set(fitRows.map(\.reading) + holdoutRows.map(\.reading))).sorted()
    print("  readingsOfInterest = \(readingsOfInterest.count) distinct readings (union of fit+holdout)")

    print("building aliased Kiwi (replaying \(donorRows.count) donor registrations from donors.tsv)...")
    let buildStart = Date()
    let kiwi = try buildAliasedKiwiFromDonorsTable(donorRows, inventory: inventory)
    print("  build done in \(String(format: "%.3f", Date().timeIntervalSince(buildStart)))s")

    // --- throughput probe (before committing to the full run) ---
    print("throughput probe...")
    let probeSlice = Array(fitRows.prefix(300))
    let probeStart = Date()
    for row in probeSlice {
        _ = try kiwi.analyze(row.inputSentence, topN: options.topN, matchOptionsRaw: Contract.matchOptionsRaw)
    }
    let probeElapsed = Date().timeIntervalSince(probeStart)
    let msPerSentence = probeSlice.isEmpty ? 0 : (probeElapsed / Double(probeSlice.count)) * 1000
    print(String(format: "  %d sentences in %.3fs = %.4f ms/sentence at topN=%d", probeSlice.count, probeElapsed, msPerSentence, options.topN))

    let rowScoringTotal = fitRows.count + holdoutRows.count
    let projectedRowScoringSec = Double(rowScoringTotal) * msPerSentence / 1000
    let upperBoundBaselineCalls = readingsOfInterest.count * options.capPerReading
    let projectedBaselineUpperSec = Double(upperBoundBaselineCalls) * msPerSentence / 1000
    print(String(format: "  projected row-scoring (fit+holdout, %d rows): %.1fs", rowScoringTotal, projectedRowScoringSec))
    print(String(format: "  projected baseline verification UPPER BOUND (%d readings * cap %d = %d calls): %.1fs "
        + "(actual will be lower — most readings won't reach the cap)",
        readingsOfInterest.count, options.capPerReading, upperBoundBaselineCalls, projectedBaselineUpperSec))

    let filteredFiles = try loadFilteredPartFiles()
    let index = BigramIndex(patterns: readingsOfInterest)
    let scanProbeStart = Date()
    var scanProbeLines = 0
    for line in try dataLines(of: filteredFiles[0]) {
        let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard cols.count >= 3 else { continue }
        scanProbeLines += 1
        let scalars = Array(String(cols[2]).unicodeScalars).map(\.value)
        _ = index.matches(in: scalars)
    }
    let scanProbeElapsed = Date().timeIntervalSince(scanProbeStart)
    let probeFileSize = max(fileSizeBytes(filteredFiles[0]), 1)
    let totalFilteredSize = filteredFiles.map(fileSizeBytes).reduce(0, +)
    let projectedScanSec = scanProbeElapsed * (Double(totalFilteredSize) / Double(probeFileSize))
    print(String(format: "  corpus AC-scan probe: %d lines (%@, %.0fMB) in %.2fs -> projected full-corpus scan "
        + "(%d files, %.0fMB total): %.1fs",
        scanProbeLines, filteredFiles[0].lastPathComponent, Double(probeFileSize) / 1_000_000, scanProbeElapsed,
        filteredFiles.count, Double(totalFilteredSize) / 1_000_000, projectedScanSec))

    let projectedTotalSec = projectedRowScoringSec + projectedBaselineUpperSec + projectedScanSec
    print(String(format: "  PROJECTED TOTAL (upper bound, cap not yet hit-rate-adjusted): %.1f min", projectedTotalSec / 60))

    if options.throughputOnly {
        print("--throughput-only: stopping here (no full run, no baseline/scoring, no file writes).")
        return
    }

    // --- wiki-sample baseline construction (independent of fit/holdout; K1b-1 correction 1) ---
    let holdoutPageIds = Set(holdoutRows.map(\.pageId))
    print("collecting baseline occurrences from filtered corpus (excluding \(holdoutPageIds.count) holdout page_ids)...")
    let collectStart = Date()
    let (occurrencesByReading, scannedLines, excludedByPageId, totalRawHits) = try collectBaselineOccurrences(
        readingsOfInterest: readingsOfInterest,
        candidateHanjaByReading: inventory.candidatesByReading,
        excludePageIds: holdoutPageIds,
        capPerReading: options.capPerReading)
    let collectElapsed = Date().timeIntervalSince(collectStart)
    let totalCollected = occurrencesByReading.values.map(\.count).reduce(0, +)
    print(String(format: "  scanned %d lines (%.1fs), excluded %d by holdout page_id, %d raw bigram hits, "
        + "%d occurrences kept after cap+leak-guard, across %d/%d readings with >=1 occurrence",
        scannedLines, collectElapsed, excludedByPageId, totalRawHits, totalCollected,
        occurrencesByReading.count, readingsOfInterest.count))

    print("verifying occurrences against aliased Kiwi and accumulating baselines (topN=\(options.topN))...")
    let baselineStart = Date()
    let (baselines, verifiedOccurrences, totalOccurrences) = try computeBaselines(
        occurrencesByReading: occurrencesByReading, orderedReadings: readingsOfInterest,
        donorRowsByReading: donorRowsByReading, kiwi: kiwi, topN: options.topN)
    let baselineElapsed = Date().timeIntervalSince(baselineStart)
    print(String(format: "  %d/%d occurrences verified (form+position match found) in %.1fs -> %d (reading,candidate) pairs have >=1 baseline sample",
        verifiedOccurrences, totalOccurrences, baselineElapsed, baselines.count))

    // --- write baseline manifest + stats (audit trail) ---
    let occWriter = try LineWriterK1(url: Paths.outDir.appendingPathComponent("baseline-occurrences.tsv"))
    occWriter.write("# baseline-occurrences.tsv — raw wiki-sample occurrences proposed for baseline estimation (pre-Kiwi-verification)")
    occWriter.write("# reading\tpage_id\tposition\tsentence")
    for reading in readingsOfInterest {
        for occ in occurrencesByReading[reading] ?? [] {
            occWriter.write([reading, occ.pageId, String(occ.position), occ.sentence].map(tsvEscape).joined(separator: "\t"))
        }
    }
    occWriter.close()

    let baselineWriter = try LineWriterK1(url: Paths.outDir.appendingPathComponent("baseline-stats.tsv"))
    baselineWriter.write("# baseline-stats.tsv — per-(reading,candidate) wiki-sample baseline mean (K1b-1, non-transductive)")
    baselineWriter.write("# reading\tcandidate\tsense_id\tsource\tsource_score\tdonor\tsample_count\tbaseline_mean")
    for key in baselines.keys.sorted() {
        let stat = baselines[key]!
        guard let info = donorInfoByPair[key] else { continue }
        baselineWriter.write([
            key.reading, key.candidate, String(info.senseId), info.source, String(info.sourceScore), info.donor,
            String(stat.count), String(format: "%.6f", stat.mean),
        ].map(tsvEscape).joined(separator: "\t"))
    }
    baselineWriter.close()
    print("  wrote baseline-occurrences.tsv (\(totalOccurrences) rows) and baseline-stats.tsv (\(baselines.count) rows)")

    // --- score fit (threshold-selection sanity) and holdout (reported accuracy) ---
    print("scoring fit rows...")
    let (fitScored, fitSurface) = try scoreRows(fitRows, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: options.topN)
    print("scoring holdout rows...")
    let (holdoutScored, holdoutSurface) = try scoreRows(holdoutRows, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: options.topN)

    for (split, rows) in [("fit", fitScored), ("holdout", holdoutScored)] {
        let writer = try LineWriterK1(url: Paths.outDir.appendingPathComponent("\(split)-scored.tsv"))
        writer.write("# \(split)-scored.tsv — per-row K1b scoring outcome")
        writer.write("# reading\tcandidate\tstatus\tpredicted\tcorrect\tno_surface_miss\tgold_surfaced\tfloorA_predicted\tfloorA_correct\tfloorB_expected\tsource\tdonor\tcandidate_count\tpage_id\tfamily")
        for r in rows {
            writer.write([
                r.reading, r.candidate, r.status, r.predicted ?? "", String(r.correct), String(r.noSurfaceMiss), String(r.goldSurfaced),
                r.floorAPredicted, String(r.floorACorrect), String(format: "%.6f", r.floorBExpected),
                r.source, r.donor, String(r.candidateCount), r.pageId, r.family,
            ].map(tsvEscape).joined(separator: "\t"))
        }
        writer.close()
    }
    print("  wrote fit-scored.tsv (\(fitScored.count) rows) and holdout-scored.tsv (\(holdoutScored.count) rows)")

    func sourceScoreOf(_ r: ScoredRow) -> Int { donorInfoByPair[PairKey(reading: r.reading, candidate: r.candidate)]?.sourceScore ?? 0 }
    func reuseCountOf(_ r: ScoredRow) -> Int { donorReuseCount[r.donor] ?? 0 }
    func tierOf(_ r: ScoredRow) -> String {
        if r.source == "anchor" || r.source == "assoc" { return "1_anchor+assoc" }
        if sourceScoreOf(r) >= 2 && !ubiquitousDonors.contains(r.donor) { return "2_plus3filterNikl" }
        return "3_plusRawOnlyNikl"
    }

    // --- secondary, direction-only 258-row eval check (NOT used for selection — 계획 §13) ---
    print("secondary check: 258-row eval set (direction-only, not used for selection)...")
    let evalTuples = try dataLines(of: Paths.evalTSV).compactMap { line -> (sentence: String, reading: String, gold: String)? in
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 3 else { return nil }
        return (String(cols[0]), String(cols[1]), String(cols[2]))
    }
    let evalScoredRows = try scoreEvalRows(evalTuples, donorRowsByReading: donorRowsByReading, baselines: baselines, inventory: inventory, kiwi: kiwi, topN: options.topN)
    try writeEvalScoredTSV(evalScoredRows)
    let evalScoredOnly = evalScoredRows.filter { $0.status == "scored" }
    let evalCorrect = evalScoredOnly.filter(\.correct).count
    let evalScored = evalScoredOnly.count
    let evalUncoveredOrNoBaseline = evalScoredRows.count - evalScored
    print("  eval258: \(evalCorrect)/\(evalScored) scored top1 (\(evalUncoveredOrNoBaseline)/\(evalScoredRows.count) uncovered/no-baseline, excluded)")

    try writeK1bReport(
        options: options, donorRows: donorRows, inventory: inventory,
        fitRows: fitRows, holdoutRows: holdoutRows,
        fitFamilies: fitFamilies, holdoutFamilies: holdoutFamilies,
        joinMismatches: joinMismatches, readingsOfInterest: readingsOfInterest,
        holdoutPageIds: holdoutPageIds, scannedLines: scannedLines, excludedByPageId: excludedByPageId,
        totalRawHits: totalRawHits, totalCollected: totalCollected, occurrenceReadingCount: occurrencesByReading.count,
        verifiedOccurrences: verifiedOccurrences, totalOccurrences: totalOccurrences, baselinePairCount: baselines.count,
        fitScored: fitScored, holdoutScored: holdoutScored, fitSurface: fitSurface, holdoutSurface: holdoutSurface,
        ubiquitousDonors: ubiquitousDonors,
        sourceScoreOf: sourceScoreOf, reuseCountOf: reuseCountOf, tierOf: tierOf,
        evalCorrect: evalCorrect, evalScored: evalScored, evalUncoveredOrNoBaseline: evalUncoveredOrNoBaseline, evalTotal: evalScoredRows.count,
        msPerSentence: msPerSentence, collectElapsed: collectElapsed, baselineElapsed: baselineElapsed)
}
