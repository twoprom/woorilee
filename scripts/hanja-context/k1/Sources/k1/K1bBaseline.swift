// Wiki-sample baseline construction for K1b (docs/plans/hanja-context-scaling-plan.md §12 K1b-1,
// correction 1 — see RunK1b.swift header for the full rationale). Streams
// .../work/hanja-context/filtered/part-*.txt ONCE, proposes candidate occurrences via
// K1bBigramIndex, and scores each surviving occurrence with the aliased Kiwi to accumulate a
// per-(reading,candidate) baseline mean — entirely independent of the fit/holdout split.
import Foundation

struct BaselineOccurrence {
    let pageId: String
    let sentence: String
    let position: Int // scalar index where the reading starts, from the bigram scan
}

func loadFilteredPartFiles() throws -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: Paths.filteredDir, includingPropertiesForKeys: nil) else {
        fail("filtered directory not found: \(Paths.filteredDir.path)")
    }
    let files = entries
        .filter { $0.lastPathComponent.hasPrefix("part-") && $0.lastPathComponent.hasSuffix(".txt") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { fail("no filtered/part-*.txt files found in \(Paths.filteredDir.path)") }
    return files
}

/// Streams the filtered corpus once. For each line: skip if its page_id is in `excludePageIds`
/// (holdout-leakage guard — the coordinator's correction 1); otherwise run the bigram scan, and for
/// each reading matched (at most once per line — first position wins, keeps one sample from
/// dominating a single repetitive line/page), skip if the RAW line contains any of that reading's
/// own candidate hanja strings (leak-analog guard — confirmed necessary empirically: holdout page
/// 1006140, excluded via the page guard, independently also contains the literal string "가경(嘉慶)").
/// Caps at `capPerReading` raw (unverified) hits; Kiwi tokenization verifies each one later.
func collectBaselineOccurrences(
    readingsOfInterest: [String],
    candidateHanjaByReading: [String: [String]],
    excludePageIds: Set<String>,
    capPerReading: Int
) throws -> (occurrences: [String: [BaselineOccurrence]], scannedLines: Int, excludedByPageId: Int, totalRawHits: Int) {
    let index = BigramIndex(patterns: readingsOfInterest)
    var counts: [String: Int] = [:]
    var out: [String: [BaselineOccurrence]] = [:]
    var scannedLines = 0
    var excludedByPageId = 0
    var totalRawHits = 0

    for url in try loadFilteredPartFiles() {
        for line in try dataLines(of: url) {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            scannedLines += 1
            let pageId = String(cols[1])
            if excludePageIds.contains(pageId) { excludedByPageId += 1; continue }
            let sentence = String(cols[2])
            let scalars = Array(sentence.unicodeScalars).map(\.value)
            let hits = index.matches(in: scalars)
            guard !hits.isEmpty else { continue }
            totalRawHits += hits.count
            var seenInLine = Set<Int>()
            for (pIdx, pos) in hits {
                guard !seenInLine.contains(pIdx) else { continue }
                let reading = index.patternStrings[pIdx]
                guard (counts[reading] ?? 0) < capPerReading else { continue }
                let candidateHanja = candidateHanjaByReading[reading] ?? []
                if candidateHanja.contains(where: { sentence.contains($0) }) { continue }
                seenInLine.insert(pIdx)
                counts[reading, default: 0] += 1
                out[reading, default: []].append(BaselineOccurrence(pageId: pageId, sentence: sentence, position: pos))
            }
        }
    }
    return (out, scannedLines, excludedByPageId, totalRawHits)
}

/// Verifies each proposed occurrence against the aliased Kiwi (does a token with form==reading
/// really sit at the scanned position?) and accumulates per-(reading,candidate) baseline means.
/// Iteration is over `orderedReadings` (caller passes a SORTED list) and, within a reading, over
/// occurrences in file-scan order — both fixed, so the float sums accumulate in the same order on
/// every run (required for byte-identical output; Dictionary iteration order is NOT stable across
/// Swift processes).
func computeBaselines(
    occurrencesByReading: [String: [BaselineOccurrence]],
    orderedReadings: [String],
    donorRowsByReading: [String: [DonorRow]],
    kiwi: KiwiRaw,
    topN: Int32
) throws -> (baselines: [PairKey: BaselineStat], verifiedOccurrences: Int, totalOccurrences: Int) {
    var baselines: [PairKey: BaselineStat] = [:]
    var verified = 0
    var total = 0
    for reading in orderedReadings {
        guard let occs = occurrencesByReading[reading] else { continue }
        let candidates = donorRowsByReading[reading] ?? []
        guard !candidates.isEmpty else { continue }
        var senseIdToCandidate: [Int: String] = [:]
        for c in candidates { senseIdToCandidate[c.senseId] = c.candidate }

        for occ in occs {
            total += 1
            let results = try kiwi.analyze(occ.sentence, topN: topN, matchOptionsRaw: Contract.matchOptionsRaw)
            let perSense = bestParseProbAtPosition(results, form: reading, position: occ.position)
            guard !perSense.isEmpty else { continue }
            verified += 1
            for (senseId, score) in perSense.sorted(by: { $0.key < $1.key }) {
                guard let candidate = senseIdToCandidate[senseId] else { continue }
                let key = PairKey(reading: reading, candidate: candidate)
                var stat = baselines[key] ?? BaselineStat()
                stat.sum += Double(score)
                stat.count += 1
                baselines[key] = stat
            }
        }
    }
    return (baselines, verified, total)
}

/// Reloads a PREVIOUSLY-WRITTEN baseline-occurrences.tsv (columns: reading, page_id, position,
/// sentence — the RAW pre-verification manifest `collectBaselineOccurrences` wrote), restricted to
/// `onlyReadings` and capped at `capPerReading` per reading (first-N in the file's own scan order —
/// deterministic, no re-scan of the corpus). Used for the matched-topN baseline re-estimate
/// (RunK1bMatched.swift): re-verifying a SMALL, targeted subset of already-collected occurrences at
/// a higher topN is far cheaper than a fresh corpus scan, and correctness only requires the
/// occurrence text + position, which this file already has.
func loadCachedOccurrences(from url: URL, onlyReadings: Set<String>, capPerReading: Int) throws -> [String: [BaselineOccurrence]] {
    var counts: [String: Int] = [:]
    var out: [String: [BaselineOccurrence]] = [:]
    for line in try dataLines(of: url) {
        let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard cols.count >= 4 else { continue }
        let reading = String(cols[0])
        guard onlyReadings.contains(reading) else { continue }
        guard (counts[reading] ?? 0) < capPerReading else { continue }
        guard let position = Int(cols[2]) else { continue }
        counts[reading, default: 0] += 1
        out[reading, default: []].append(BaselineOccurrence(pageId: String(cols[1]), sentence: String(cols[3]), position: position))
    }
    return out
}

/// Reloads a PREVIOUSLY-WRITTEN baseline-stats.tsv (columns: reading, candidate, sense_id, source,
/// source_score, donor, sample_count, baseline_mean) instead of re-scanning the corpus — used by the
/// gold_surfaced diagnostic (RunK1bDiagnose.swift) so it doesn't have to repeat the ~17-minute
/// corpus-scan + verification pass just to re-score rows with an additional field. `mean` is stored
/// at 6 decimal digits, so reconstructing `sum = mean * count` loses a little precision relative to
/// the original in-memory accumulation — negligible for a diagnostic re-score (it would not be
/// acceptable as the basis for a fresh gate number, only for re-deriving a field on an existing one).
func loadBaselineStats(from url: URL) throws -> [PairKey: BaselineStat] {
    var out: [PairKey: BaselineStat] = [:]
    for line in try dataLines(of: url) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 8, let count = Int(cols[6]), let mean = Double(cols[7]) else { continue }
        let key = PairKey(reading: String(cols[0]), candidate: String(cols[1]))
        out[key] = BaselineStat(sum: mean * Double(count), count: count)
    }
    guard !out.isEmpty else { fail("baseline-stats.tsv produced no rows at \(url.path)") }
    return out
}
