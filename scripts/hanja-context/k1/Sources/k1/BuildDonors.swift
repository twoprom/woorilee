// build-donors: donor inventory + coverage (docs/plans/hanja-context-scaling-plan.md §12
// K1a-2/K1a-3). Registers a real alias for every (reading, candidate) pair we can find a working
// donor for, across three sources in priority order (a) anchor -> (b) NIKL discriminative simple
// word -> (c) association-table top feature, and reports empirical coverage as a BRACKET across
// filter tiers (coordinator review, Part 3), not a single headline number. Tiers are computed by
// POST-HOC FILTERING of the one priority-ordered pass's rows (same methodology the coordinator
// used auditing donors.tsv directly) — not independent re-registration per tier, since "assoc
// 단독" etc. mean "this source's exclusive contribution under a->b->c priority", not its
// standalone reach if tried alone (those are very different numbers; an earlier version of this
// file computed the latter by mistake and got wildly inflated tier numbers as a result).
//
// POS-category fix (Part 3 task A): kiwi_builder_add_alias_word_with_def takes ONE pos for both
// the alias and the donor lookup, so a donor's own tag becomes the READING's registered tag. The
// original pipeline let any donor's tag decide this, registering 한자어 noun readings as VV/VA/MAG
// in some NIKL cases — a category error, not a quality issue. Fixed here: every registration is
// restricted to a POS the reading itself natively carries (NativeTags.swift), never falling back
// across POS to accommodate a donor.
import CKiwi
import Foundation

struct DonorRow {
    let reading: String
    let candidate: String
    let senseId: Int
    let donor: String
    let donorPos: String
    let source: String // anchor | nikl | assoc
    let sourceScore: Int
}

struct FailureRow {
    let reading: String
    let candidate: String
    let senseId: Int
    let donor: String
    let donorPos: String
    let source: String
    let sourceScore: Int
    let error: String
}

struct RegressionRow {
    let sentence: String
    let before: String
    let after: String
    let category: String // selfFlipOnly | spillover | segmentationChanged
}

func tsvEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

struct SourceSpec {
    let name: String
    let isAnchor: Bool
    let lookup: (PairKey) -> [DonorCandidate]
}

/// Expands a pair's candidate donor list into concrete (donor, pos, sourceScore) attempts,
/// restricted to the reading's native tags. Anchor donors don't carry a pos (anchors.tsv doesn't
/// record one) so every native tag is tried, NNG before NNP; NIKL/assoc donors already carry
/// their own analyzed/recorded pos, so they're included only if that pos is native to the reading
/// — this is the actual POS-category fix, applied uniformly across all three sources.
func attemptsFor(candidates: [DonorCandidate], nativeTags: Set<String>, isAnchor: Bool) -> [(donor: String, pos: String, sourceScore: Int)] {
    var attempts: [(donor: String, pos: String, sourceScore: Int)] = []
    if isAnchor {
        for cand in candidates {
            for pos in ["NNG", "NNP"] where nativeTags.contains(pos) {
                attempts.append((cand.donor, pos, cand.sourceScore))
            }
        }
    } else {
        for cand in candidates where nativeTags.contains(cand.pos ?? "") {
            attempts.append((cand.donor, cand.pos!, cand.sourceScore))
        }
    }
    return attempts
}

/// The ONE priority-ordered registration pass (a -> b(nikl) -> c per pair, first success wins),
/// against a single accumulating builder. This is the only registration pass build-donors runs;
/// every bracket tier is a post-hoc filter of its resulting rows (see file header).
func runRegistrationPass(
    modelPath: String,
    pairs: [PairKey],
    candidateIndex: [PairKey: Int],
    nativeTags: [String: Set<String>],
    sources: [SourceSpec]
) throws -> (builder: KiwiBuilderRaw, donorRows: [DonorRow], failureRows: [FailureRow]) {
    let builder = try KiwiBuilderRaw(modelPath: modelPath)
    var donorRows: [DonorRow] = []
    var failureRows: [FailureRow] = []

    for pair in pairs {
        let senseId = candidateIndex[pair]!
        let tags = nativeTags[pair.reading] ?? ["NNG"]
        var succeeded = false

        sourceLoop: for spec in sources {
            let attempts = attemptsFor(candidates: spec.lookup(pair), nativeTags: tags, isAnchor: spec.isAnchor)
            for attempt in attempts {
                let rc = builder.addAliasWordWithDef(
                    alias: pair.reading, pos: attempt.pos, senseId: Int32(senseId), dialect: 0, score: 0, origWord: attempt.donor)
                if rc == 0 {
                    donorRows.append(DonorRow(
                        reading: pair.reading, candidate: pair.candidate, senseId: senseId,
                        donor: attempt.donor, donorPos: attempt.pos, source: spec.name, sourceScore: attempt.sourceScore))
                    succeeded = true
                    break sourceLoop
                } else {
                    let err = kiwi_error().map { String(cString: $0) } ?? "?"
                    kiwi_clear_error()
                    failureRows.append(FailureRow(
                        reading: pair.reading, candidate: pair.candidate, senseId: senseId,
                        donor: attempt.donor, donorPos: attempt.pos, source: spec.name, sourceScore: attempt.sourceScore, error: err))
                }
            }
            if succeeded { break }
        }
    }
    return (builder, donorRows, failureRows)
}

func runBuildDonors() throws {
    print("=== build-donors ===")
    try ensureOutDir()

    print("loading target inventory...")
    let inventory = try TargetInventory.load()
    print("  \(inventory.allPairs.count) (reading,candidate) pairs across \(inventory.candidatesByReading.count) readings")

    print("loading source (a) anchor donors...")
    let anchorDonors = try loadAnchorDonors()
    print("  \(anchorDonors.count) pairs have >=1 anchor donor candidate")

    print("loading source (c) association-table donors...")
    let assocDonors = try loadAssocDonors()
    print("  \(assocDonors.count) pairs have >=1 NNG/NNP association-table donor candidate")

    print("building plain (unregistered) Kiwi for NIKL tokenization + native-tag detection + baseline comparison...")
    let plainKiwi = try KiwiBuilderRaw(modelPath: Paths.modelDir.path).build()

    print("loading source (b) NIKL discriminative-morpheme donors (tokenizing definitions)...")
    let niklStart = Date()
    let niklDonorsRaw = try loadNiklDonors(kiwi: plainKiwi)
    print("  \(niklDonorsRaw.count) pairs have >=1 discriminative NIKL donor candidate (\(String(format: "%.1f", Date().timeIntervalSince(niklStart)))s)")

    print("computing each reading's native POS tag(s) (direct dictionary lookup, kiwi_find_morphemes)...")
    let (nativeTags, fallbackCount) = computeNativeTags(Array(inventory.candidatesByReading.keys), kiwi: plainKiwi)
    let bothTagCount = nativeTags.values.filter { $0.count > 1 }.count
    print("  \(nativeTags.count) readings tagged; \(fallbackCount) exist as neither NNG nor NNP and fell back to {NNG}; "
        + "\(bothTagCount) are natively both NNG and NNP")

    // --- ubiquity: donor strings that show up as a NIKL CANDIDATE (not necessarily a winner)
    // across many DIFFERENT pairs (5b's ubiquity/DF filter rationale, README 5b 절). ---
    var niklDonorPairCount: [String: Int] = [:]
    for (_, cands) in niklDonorsRaw {
        for donor in Set(cands.map(\.donor)) { niklDonorPairCount[donor, default: 0] += 1 }
    }
    let ubiquitousDonors = Set(niklDonorPairCount.filter { $0.value >= 11 }.keys)
    print("  \(ubiquitousDonors.count) NIKL donor strings reused across >=11 pairs (candidate pool, not just winners)")

    // --- baseline build time (fresh builder, zero registrations) ---
    let baselineStart = Date()
    _ = try KiwiBuilderRaw(modelPath: Paths.modelDir.path).build()
    let baselineBuildTime = Date().timeIntervalSince(baselineStart)

    let anchorSpec = SourceSpec(name: "anchor", isAnchor: true) { anchorDonors[$0] ?? [] }
    let assocSpec = SourceSpec(name: "assoc", isAnchor: false) { assocDonors[$0] ?? [] }
    let niklSpec = SourceSpec(name: "nikl", isAnchor: false) { niklDonorsRaw[$0] ?? [] } // native-tag-fixed, no quality filter yet

    // --- the ONE official pass: a -> b(nikl) -> c per pair, native-tag-fixed, no quality filter
    // on nikl beyond the fix itself — this is the widest CORRECT tier (upper bound). All bracket
    // tiers below are post-hoc filters of ITS rows, matching the coordinator's own auditing
    // methodology exactly. aliasedTotalStart covers builder init through build(), matching
    // baselineBuildTime and replicate's warm-up methodology. ---
    print("registering donors (priority a -> b(nikl) -> c, native-tag-fixed)...")
    let aliasedTotalStart = Date()
    let registrationStart = Date()
    let pass = try runRegistrationPass(
        modelPath: Paths.modelDir.path, pairs: inventory.allPairs, candidateIndex: inventory.candidateIndex,
        nativeTags: nativeTags, sources: [anchorSpec, niklSpec, assocSpec])
    let registrationElapsed = Date().timeIntervalSince(registrationStart)
    let donorRows = pass.donorRows
    let failureRows = pass.failureRows
    print("registration pass done: \(donorRows.count)/\(inventory.allPairs.count) pairs covered, "
        + "\(failureRows.count) failed attempts logged, \(String(format: "%.1f", registrationElapsed))s")

    let aliasedBuildStart = Date()
    let aliasedKiwi = try pass.builder.build()
    let aliasedBuildOnlyTime = Date().timeIntervalSince(aliasedBuildStart)
    let aliasedTotalTime = Date().timeIntervalSince(aliasedTotalStart)
    print(String(
        format: "build time: baseline(init+build, 0 registrations)=%.3fs "
            + "aliased(init+registrations+build, %d registrations)=%.3fs "
            + "(pure build() call alone=%.3fs)",
        baselineBuildTime, donorRows.count, aliasedTotalTime, aliasedBuildOnlyTime))

    // --- bracket tiers: post-hoc filters of donorRows (the SAME methodology the coordinator used
    // auditing the pre-fix donors.tsv — "assoc 단독" etc. mean "exclusive contribution under
    // a->b->c priority", not standalone reach if tried alone). ---
    let anchorRows = donorRows.filter { $0.source == "anchor" }
    let assocRows = donorRows.filter { $0.source == "assoc" }
    let niklRows = donorRows.filter { $0.source == "nikl" } // already native-tag-fixed -> "체언만" is a no-op post-fix
    let niklDisc2Rows = niklRows.filter { $0.sourceScore >= 2 }
    let niklDisc2UbiqRows = niklDisc2Rows.filter { !ubiquitousDonors.contains($0.donor) }

    func pairSet(_ rows: [DonorRow]) -> Set<PairKey> { Set(rows.map { PairKey(reading: $0.reading, candidate: $0.candidate) }) }
    let anchorOnlySet = pairSet(anchorRows)
    let assocOnlySet = pairSet(assocRows)
    let niklRawOnlySet = pairSet(niklRows)
    let niklDisc2OnlySet = pairSet(niklDisc2Rows)
    let niklDisc2UbiqOnlySet = pairSet(niklDisc2UbiqRows)
    let anchorAssocSet = anchorOnlySet.union(assocOnlySet)
    let threeFilterTierSet = anchorAssocSet.union(niklDisc2UbiqOnlySet)
    let rawTierSet = anchorAssocSet.union(niklRawOnlySet) // == full donorRows coverage, cross-checked in the report
    print("  anchor=\(anchorOnlySet.count) assoc=\(assocOnlySet.count) nikl원본=\(niklRawOnlySet.count) "
        + "nikl+판별도≥2=\(niklDisc2OnlySet.count) nikl+판별도≥2+범용제외=\(niklDisc2UbiqOnlySet.count)")

    // --- parse regression on the 258-row eval set: plain vs the OFFICIAL (native-tag-fixed, raw)
    // aliased kiwi, full token sequence. Classified into 3 kinds (unchanged methodology from the
    // pre-fix run) so the delta vs the 75/258 pre-fix baseline is directly attributable. ---
    let targetReadings = Set(inventory.candidatesByReading.keys)
    let evalSentences = try dataLines(of: Paths.evalTSV).compactMap { line -> String? in
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard !cols.isEmpty, !cols[0].isEmpty else { return nil }
        return String(cols[0])
    }
    var regressions: [RegressionRow] = []
    for sentence in evalSentences {
        let beforeTokens = try plainKiwi.analyze(sentence, topN: Contract.topN, matchOptionsRaw: Contract.matchOptionsRaw).first?.tokens ?? []
        let afterTokens = try aliasedKiwi.analyze(sentence, topN: Contract.topN, matchOptionsRaw: Contract.matchOptionsRaw).first?.tokens ?? []
        let beforeSeq = beforeTokens.map { "\($0.form)/\($0.tag)" }.joined(separator: ",")
        let afterSeq = afterTokens.map { "\($0.form)/\($0.tag)" }.joined(separator: ",")
        guard beforeSeq != afterSeq else { continue }

        let category: String
        if beforeTokens.count == afterTokens.count, zip(beforeTokens, afterTokens).allSatisfy({ $0.form == $1.form }) {
            let tagDiffs = zip(beforeTokens, afterTokens).filter { $0.tag != $1.tag }
            category = tagDiffs.allSatisfy { targetReadings.contains($0.0.form) } ? "selfFlipOnly" : "spillover"
        } else {
            category = "segmentationChanged"
        }
        regressions.append(RegressionRow(sentence: sentence, before: beforeSeq, after: afterSeq, category: category))
    }
    let selfFlipCount = regressions.filter { $0.category == "selfFlipOnly" }.count
    let spilloverCount = regressions.filter { $0.category == "spillover" }.count
    let segChangeCount = regressions.filter { $0.category == "segmentationChanged" }.count
    print("parse regression on \(evalSentences.count)-row eval set (POST-FIX): \(regressions.count)/\(evalSentences.count) sentences changed "
        + "(pre-fix baseline was 75/258) — selfFlipOnly=\(selfFlipCount) spillover=\(spilloverCount) segmentationChanged=\(segChangeCount)")

    // --- write donors.tsv / donor-failures.tsv ---
    let donorsURL = Paths.outDir.appendingPathComponent("donors.tsv")
    let donorsWriter = try LineWriterK1(url: donorsURL)
    donorsWriter.write("# donors.tsv — K1a-2 registered donor per covered (reading,candidate) pair (native-tag-fixed, no extra quality filter — the upper-bound tier)")
    donorsWriter.write("# reading\tcandidate\tsense_id\tdonor\tdonor_pos\tsource\tsource_score")
    for row in donorRows.sorted(by: { ($0.reading, $0.candidate) < ($1.reading, $1.candidate) }) {
        donorsWriter.write([
            row.reading, row.candidate, String(row.senseId), row.donor, row.donorPos, row.source, String(row.sourceScore),
        ].map(tsvEscape).joined(separator: "\t"))
    }
    donorsWriter.close()

    let failuresURL = Paths.outDir.appendingPathComponent("donor-failures.tsv")
    let failuresWriter = try LineWriterK1(url: failuresURL)
    failuresWriter.write("# donor-failures.tsv — every failed kiwi_builder_add_alias_word_with_def attempt during build-donors")
    failuresWriter.write("# reading\tcandidate\tsense_id\tdonor\tdonor_pos\tsource\tsource_score\terror")
    for row in failureRows.sorted(by: { ($0.reading, $0.candidate) < ($1.reading, $1.candidate) }) {
        failuresWriter.write([
            row.reading, row.candidate, String(row.senseId), row.donor, row.donorPos, row.source, String(row.sourceScore), row.error,
        ].map(tsvEscape).joined(separator: "\t"))
    }
    failuresWriter.close()
    print("wrote \(donorRows.count) rows to \(donorsURL.path)")
    print("wrote \(failureRows.count) rows to \(failuresURL.path)")

    // --- D1 comparison, per tier ---
    print("loading D1 seed pairs for comparison...")
    let d1Pairs = try loadD1SeedPairs()

    try writeCoverageReport(
        inventory: inventory,
        anchorOnlySet: anchorOnlySet,
        assocOnlySet: assocOnlySet,
        anchorAssocSet: anchorAssocSet,
        niklRawOnlySet: niklRawOnlySet,
        niklDisc2OnlySet: niklDisc2OnlySet,
        niklDisc2UbiqOnlySet: niklDisc2UbiqOnlySet,
        rawTierSet: rawTierSet,
        threeFilterTierSet: threeFilterTierSet,
        officialCoveredSet: pairSet(donorRows),
        d1Pairs: d1Pairs,
        nativeTagFallbackCount: fallbackCount,
        bothTagCount: bothTagCount,
        ubiquitousDonorCount: ubiquitousDonors.count,
        baselineBuildTime: baselineBuildTime,
        aliasedBuildTime: aliasedTotalTime,
        aliasedBuildOnlyTime: aliasedBuildOnlyTime,
        registrationElapsed: registrationElapsed,
        failureCount: failureRows.count,
        regressions: regressions,
        evalSentenceCount: evalSentences.count,
        aliasedKiwi: aliasedKiwi,
        donorRowsForSpotCheck: donorRows
    )
}

final class LineWriterK1 {
    private let handle: FileHandle
    private var buffer = Data()
    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func write(_ line: String) {
        buffer.append(Data(line.utf8))
        buffer.append(0x0A)
        if buffer.count > 1 << 20 { flush() }
    }
    func flush() {
        if !buffer.isEmpty {
            handle.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
    func close() {
        flush()
        try? handle.close()
    }
}
