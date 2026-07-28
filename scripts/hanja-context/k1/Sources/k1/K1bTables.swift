// K1b Part 1 — loaders for donors.tsv (replay) and the coordinator-built measure/{fit,holdout}.tsv
// (docs/plans/hanja-context-scaling-plan.md §12 K1b). These files already exist on disk (the
// coordinator built measure/*.tsv directly — see RunK1b.swift header) — this file only reads them.
import Foundation

/// One row of scripts/hanja-context/k1/../../../wooriHanjaModel/work/hanja-context/k1/donors.tsv,
/// re-parsed from the FILE (not recomputed) so K1b replays the exact same registrations K1a made.
func loadDonorsTable() throws -> [DonorRow] {
    let url = Paths.outDir.appendingPathComponent("donors.tsv")
    var rows: [DonorRow] = []
    for line in try dataLines(of: url) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 7, let senseId = Int(cols[2]), let sourceScore = Int(cols[6]) else { continue }
        rows.append(DonorRow(
            reading: String(cols[0]), candidate: String(cols[1]), senseId: senseId,
            donor: String(cols[3]), donorPos: String(cols[4]), source: String(cols[5]), sourceScore: sourceScore))
    }
    guard !rows.isEmpty else { fail("donors.tsv produced no rows at \(url.path)") }
    return rows
}

/// Replays donors.tsv's registrations against a single fresh builder, in the SAME order K1a's
/// build-donors originally registered them (`inventory.allPairs`: reading file-order, then
/// sense_id/rank ascending) — NOT donors.tsv's own on-disk (reading,candidate-STRING) sort order.
///
/// Order genuinely matters here, empirically: `kiwi_builder_add_alias_word_with_def`'s origWord
/// lookup can resolve against an alias THIS SAME accumulating builder already created for an
/// EARLIER sense of the same reading — e.g. 신밀's sense_id=1 (身密) registers alias "신밀"/NNG
/// borrowing from donor 부처; that registration itself makes "신밀"/NNG a real, findable morpheme
/// in the builder, which sense_id=4 (愼密, donor="신밀"/NNG per donors.tsv) then borrows from in
/// turn. Replaying in donors.tsv's alphabetical-by-candidate order registers 愼密 before 身密 for
/// this reading and the lookup fails ("cannot find the original morpheme 신밀/NNG") even though the
/// original run succeeded — confirmed by reproducing the failure once, then fixing it here.
func buildAliasedKiwiFromDonorsTable(_ donorRows: [DonorRow], inventory: TargetInventory) throws -> KiwiRaw {
    var pairOrderIndex: [PairKey: Int] = [:]
    for (i, pair) in inventory.allPairs.enumerated() { pairOrderIndex[pair] = i }
    let replayOrder = donorRows.sorted {
        (pairOrderIndex[PairKey(reading: $0.reading, candidate: $0.candidate)] ?? Int.max)
            < (pairOrderIndex[PairKey(reading: $1.reading, candidate: $1.candidate)] ?? Int.max)
    }

    let builder = try KiwiBuilderRaw(modelPath: Paths.modelDir.path)
    for row in replayOrder {
        let rc = builder.addAliasWordWithDef(
            alias: row.reading, pos: row.donorPos, senseId: Int32(row.senseId), dialect: 0, score: 0, origWord: row.donor)
        guard rc == 0 else {
            fail("replay registration failed for \(row.reading)/\(row.candidate) <- \(row.donor)/\(row.donorPos): "
                + kiwiLastError("replay").description)
        }
    }
    return try builder.build()
}

/// One row of measure/fit.tsv or measure/holdout.tsv (coordinator-built; see RunK1b.swift header
/// for the columns and how the file was produced — leak-filtered, family-disjoint-split D1 token
/// seeds joined against donors.tsv).
struct MeasureRow {
    let reading: String
    let candidate: String
    let senseId: Int
    let donor: String
    let donorPos: String
    let source: String
    let family: String
    let pageId: String
    let spanStart: Int
    let spanLen: Int
    let inputSentence: String
}

/// cols[2] ("sense_id") etc. fail Int(...) parsing on the header row, so the header is skipped for
/// free without a separate string comparison — same trick as the seed-part-file loaders elsewhere.
func loadMeasureRows(_ url: URL) throws -> [MeasureRow] {
    var rows: [MeasureRow] = []
    for line in try dataLines(of: url) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 11,
              let senseId = Int(cols[2]), let spanStart = Int(cols[8]), let spanLen = Int(cols[9])
        else { continue }
        rows.append(MeasureRow(
            reading: String(cols[0]), candidate: String(cols[1]), senseId: senseId,
            donor: String(cols[3]), donorPos: String(cols[4]), source: String(cols[5]),
            family: String(cols[6]), pageId: String(cols[7]), spanStart: spanStart, spanLen: spanLen,
            inputSentence: String(cols[10])))
    }
    guard !rows.isEmpty else { fail("measure file produced no rows: \(url.path)") }
    return rows
}

// --- bucketing helpers shared by the scoring breakdown and the report writer ---

func niklTier(_ sourceScore: Int) -> String {
    if sourceScore >= 3 { return "≥3" }
    if sourceScore >= 2 { return "≥2" }
    return "1"
}

func reuseBucket(_ n: Int) -> String {
    switch n {
    case ..<2: return "1"
    case 2...5: return "2-5"
    case 6...10: return "6-10"
    default: return "11+"
    }
}

/// Bucket boundaries mirror the coordinator's own framing of holdout's candidate-count
/// distribution (11-20 / 21+) so our re-measurement is directly comparable.
func candidateCountBucket(_ n: Int) -> String {
    switch n {
    case 1: return "1"
    case 2: return "2"
    case 3...5: return "3-5"
    case 6...10: return "6-10"
    case 11...20: return "11-20"
    default: return "21+"
    }
}
