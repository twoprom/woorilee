// Step R1c — document/session replay simulation.
//     Copyright (C) 2026 Seungjin Lee.
//
// docs/plans/hanja-context-scaling-plan.md §6 R1c: replays each document in
// eval/hanja-context-session-replay.tsv (built by
// scripts/hanja-context/build_session_replay_set.py — see that script's docstring for the
// data-prep side, including the "reading-pool discrepancy" and "one-reading-per-document"
// notes) sentence by sentence through a FRESH `HanjaSessionContext` per document, measuring
// whether R1a's session vocabulary/last-selection-prior axis improves ranking on a target
// reading's bare reappearance later in the same document.
//
// Style mirrors HanjaContextEvalV2Tests.swift closely (same static fixture loading — Kiwi built
// directly from the repo's KiwiModels, hanja.txt, freq tables, hanja-context.txt association
// table — none of it via the app's warm-up singletons) and reuses its `applyContextReranking` +
// "PANEL ordering via rankWithContext" pattern rather than `analyzeClauseDetailed` (which needs a
// live `HanjaDictionaryService` instance). Self-skips (prints and returns) if the Kiwi model
// directory is missing, matching that file's convention.
//
// Deliberate simplifications (see also the report handed to the coordinator):
// - Per spec §2 step 3: only the `first`-role sentence simulates a user selection
//   (`recordCommittedClause(selections: [(reading, answer)])`); every other sentence (context AND
//   later) commits with `selections: []` — no auto-conversion simulation, so a wrong auto-convert
//   never pollutes the session's selection prior. This is a known simplification, not a bug.
// - `KiwiAnalysisService.clauseContentFeatures(from:excludingRangeOverlapping:)` (the function that
//   derives the R1a commit-time "clause-wide stable features") is `private` to that file, so this
//   harness reimplements the identical logic locally (`stableClauseContentFeatures`) against the
//   same PUBLIC `isContextContentMorphemeTag` filter and `form/TAG` feature-key format — verified
//   to match by construction, not by re-deriving from a different contract.
// - Session ON/OFF ranks are derived by calling `applyContextReranking` ONCE per sentence (with
//   `sessionInputs` = the CURRENT session snapshot — this is also the timed "session ON analysis"
//   for the latency measurement) to obtain the target segment's `contextFeatures`/
//   `contextDominantHanja` (these do NOT depend on `sessionInputs` — only the boost/ranking step
//   does, confirmed by reading `applyContextReranking`'s body), then computing the ON and OFF
//   candidate orders manually via `rankWithContext(..., sessionBoosts:)` (session boosts included
//   vs. empty). This avoids a second, redundant `applyContextReranking` call per sentence.
// - Coordinator-confirmed cap (2026-07-25): the "later" headline bucket caps at 10 measured pairs
///  per (document, reading) — one document (조선/朝鮮, pageID 495) had 191 bare "later"
//   reappearances on its own in the uncapped fixture, which would dominate the aggregate. Both the
//   capped headline and the uncapped total are reported side by side, never just one.
// - Interpretation of the two ambiguous-scope asserts in spec §2 (flagged in the report): both
//   "measured later pairs (capped) >= 100" and "session ON later top1 >= OFF later top1" are
//   evaluated against the COMBINED total of the two later buckets (`firstSucceeded` — the normal
//   case, a confirmed selection prior exists — plus `vocabOnly` — the first-role sentence itself
//   segMiss'd, so only the session vocabulary axis, not the selection prior, can be in play for
//   that document/reading). The per-bucket breakdown is still printed separately.
// - A `first`-role sentence whose target segment segMiss'es proceeds with NO selection prior
//   recorded for that reading in that document (spec §2 step 2's explicit instruction); its
//   document's `later` sentences for that reading are still measured, just bucketed as
//   "vocabOnly" instead of the normal bucket.

import Darwin
import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextSessionReplayTests: XCTestCase {
    private struct ReplayRow {
        let pageID: String
        let seq: Int
        let role: String
        let reading: String
        let answer: String
        let sentence: String
    }

    /// Paired session-ON/session-OFF rank outcome accumulator for one measurement bucket.
    private struct RankPairOutcome {
        var n = 0
        var top1On = 0
        var top1Off = 0
        var top3On = 0
        var top3Off = 0

        mutating func record(rankOn: Int?, rankOff: Int?) {
            n += 1
            if let rankOn, rankOn == 1 { top1On += 1 }
            if let rankOn, rankOn <= 3 { top3On += 1 }
            if let rankOff, rankOff == 1 { top1Off += 1 }
            if let rankOff, rankOff <= 3 { top3Off += 1 }
        }
    }

    private struct ReplayResult {
        var docCount = 0
        var totalSentences = 0
        var firstSegMiss = 0
        var laterSegMiss = 0
        /// Target segment found but `row.answer` absent from `candidateLookup`'s own candidate
        /// list — should not happen (the fixture's `answer` column came from hanja.txt candidates
        /// for that reading), tracked defensively rather than silently skipped.
        var answerMiss = 0

        /// `first`-role sentences: session ON/OFF measured at the moment of the gloss itself — no
        /// selection prior can exist yet for this reading in this document, so this isolates the
        /// session VOCABULARY axis alone (spec §2 step 2's "어휘 축 단독 효과").
        var firstOutcome = RankPairOutcome()

        /// `later`-role sentences in documents where this reading's `first` sentence found its
        /// segment (a selection prior WAS recorded) — the primary R1c measurement (vocabulary +
        /// last-selection-prior combined). Capped at `laterCapPerDocumentReading` per
        /// (document, reading); `*Uncapped` mirrors it with no cap.
        var laterNormalCapped = RankPairOutcome()
        var laterNormalUncapped = RankPairOutcome()

        /// `later`-role sentences in documents where `first` segMiss'd for this reading — no
        /// selection prior exists, so only the session vocabulary axis can explain any effect.
        var laterVocabOnlyCapped = RankPairOutcome()
        var laterVocabOnlyUncapped = RankPairOutcome()

        /// Per-reading breakdown of the primary (normal, capped) later bucket.
        var perReadingLaterCapped: [String: RankPairOutcome] = [:]

        mutating func recordLater(rankOn: Int?, rankOff: Int?, reading: String, firstSucceeded: Bool, withinCap: Bool) {
            if firstSucceeded {
                laterNormalUncapped.record(rankOn: rankOn, rankOff: rankOff)
                if withinCap {
                    laterNormalCapped.record(rankOn: rankOn, rankOff: rankOff)
                    perReadingLaterCapped[reading, default: RankPairOutcome()].record(rankOn: rankOn, rankOff: rankOff)
                }
            } else {
                laterVocabOnlyUncapped.record(rankOn: rankOn, rankOff: rankOff)
                if withinCap {
                    laterVocabOnlyCapped.record(rankOn: rankOn, rankOff: rankOff)
                }
            }
        }
    }

    // MARK: - Shared fixtures (mirrors HanjaContextEvalV2Tests exactly — separate static
    // properties, deliberately NOT shared across files, since each test file must be able to run
    // standalone via `-only-testing`)

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let modelDir = repoRoot().appendingPathComponent("woorilee/KiwiModels")
    private static let kiwiModelsAvailable: Bool = FileManager.default.fileExists(atPath: modelDir.path)

    private static let kiwi: Kiwi? = {
        guard kiwiModelsAvailable else { return nil }
        return try? KiwiBuilder(modelPath: modelDir.path).build()
    }()

    private static let hanjaTable: HanjaTable? = {
        LibHangul.loadHanjaTable(filename: repoRoot().appendingPathComponent("woorilee/data/hanja/hanja.txt").path)
    }()

    private static let freqTable: HanjaFrequencyTable = {
        let root = repoRoot()
        return HanjaFrequencyTable(
            characterFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")],
            wordFrequencyURLs: [root.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")]
        )
    }()

    private static let dominantMap: [String: String] = {
        let root = repoRoot()
        guard let text = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja.txt"), encoding: .utf8)
        else {
            return [:]
        }
        return buildDominantHanjaMap(
            dictionaryLines: text.split(separator: "\n", omittingEmptySubsequences: true),
            frequency: freqTable.frequency(for:)
        )
    }()

    /// Association table parsed directly from the repo's `.txt` (not the app-bundled `.bin`,
    /// mirroring HanjaContextEvalV2Tests exactly) via the nonisolated static parser — deliberately
    /// NOT HanjaContextAssociationStore.shared, so this test never depends on app warm-up ordering.
    private static let associationTable: [String: [String: [String: Double]]] = {
        let root = repoRoot()
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8)
        else {
            return [:]
        }
        return HanjaContextAssociationStore.parse(contents: contents)
    }()

    private static let replayRows: [ReplayRow] = {
        let url = repoRoot().appendingPathComponent("eval/hanja-context-session-replay.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var rows: [ReplayRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count == 6, let seq = Int(c[1]) else { continue }
            rows.append(ReplayRow(pageID: c[0], seq: seq, role: c[2], reading: c[3], answer: c[4], sentence: c[5]))
        }
        return rows
    }()

    /// Mirrors HanjaContextEvalV2Tests.candidateLookup exactly (HanjaDictionaryService.exactCandidates(for:)'s
    /// numeric-first / dictionary-merge-with-empty-personalization contract) — duplicated rather than
    /// shared because it is `private` to that file.
    private static func candidateLookup(_ key: String) -> [HanjaCandidate] {
        let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
        if !numericCandidates.isEmpty { return numericCandidates }

        guard let table = hanjaTable, let list = LibHangul.searchHanja(table: table, key: key) else { return [] }
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(reading: list.getNthKey(i) ?? key, value: value,
                                      comment: list.getNthComment(i) ?? "", source: .system, baseRank: i)
        }
        let merged = mergeHanjaCandidates(userEntries: [], systemCandidates: seeds,
                                          usageCounts: [:], frequencyLookup: freqTable.frequency(for:))
        return merged.filter { $0.value != $0.reading }
    }

    /// Local reimplementation of `KiwiAnalysisService`'s `private` `clauseContentFeatures(from:
    /// excludingRangeOverlapping:)` with no exclusion (the whole-clause "stable features" variant
    /// R1a's commit path uses) — see the file-level doc comment's second bullet.
    private static func stableClauseContentFeatures(from tokens: [Token]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            guard KiwiAnalysisService.isContextContentMorphemeTag(token.tag) else { continue }
            let feature = "\(token.form)/\(token.tag.description)"
            guard !seen.contains(feature) else { continue }
            seen.insert(feature)
            result.append(feature)
        }
        return result
    }

    private static func groupIntoDocuments(_ rows: [ReplayRow]) -> [[ReplayRow]] {
        var documents: [[ReplayRow]] = []
        var current: [ReplayRow] = []
        var currentPageID: String?
        for row in rows {
            if row.pageID != currentPageID {
                if !current.isEmpty { documents.append(current) }
                current = []
                currentPageID = row.pageID
            }
            current.append(row)
        }
        if !current.isEmpty { documents.append(current) }
        return documents
    }

    private static func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int((Double(sortedValues.count - 1) * fraction).rounded())
        return sortedValues[min(max(index, 0), sortedValues.count - 1)]
    }

    private static let laterCapPerDocumentReading = 10

    /// Replays every document independently (a FRESH `HanjaSessionContext` per document — session
    /// state is never shared across documents, spec §4) and accumulates the measurement buckets
    /// described in `ReplayResult` plus PAIRED session-ON/session-OFF `applyContextReranking` wall
    /// times (µs, mach clock) for every sentence — the OFF call here is timing-only (its return
    /// value is discarded; ranking/commit flow always uses the ON call's result, exactly as
    /// before), added so the latency report can separate "existing pipeline cost for a long wiki
    /// clause" from "R1's session axis marginal cost" (coordinator request, 2026-07-25). Per
    /// sentence, the ON/OFF measurement order is randomized (`Bool.random()`) rather than fixed,
    /// so a systematic cache/branch-predictor warm-up advantage for whichever call runs SECOND
    /// does not bias the aggregate delta in one fixed direction across all ~12,855 sentences —
    /// with a fixed order that per-call bias would be a constant, not noise, and would corrupt the
    /// delta's sign/magnitude; randomizing turns it into zero-mean noise that averages out over
    /// many paired samples.
    private static func replay(
        _ rows: [ReplayRow]
    ) -> (result: ReplayResult, latenciesOnUs: [Double], latenciesOffUs: [Double], latencyDeltasUs: [Double]) {
        var result = ReplayResult()
        guard let kiwi else { return (result, [], [], []) }

        let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in
            associationTable[reading]?[hanja]
        }

        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let ticksToMicroseconds = { (ticks: UInt64) -> Double in
            Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1000.0
        }

        var latenciesOnUs: [Double] = []
        var latenciesOffUs: [Double] = []
        var latencyDeltasUs: [Double] = []
        let documents = groupIntoDocuments(rows)
        result.docCount = documents.count

        for docRows in documents {
            var session = HanjaSessionContext()
            var firstSucceededForReading: [String: Bool] = [:]
            var laterCountForReading: [String: Int] = [:]

            for row in docRows {
                result.totalSentences += 1

                var clauseFeatures: [String] = []
                var selections: [(reading: String, value: String)] = []

                if let analysisResults = try? kiwi.analyze(
                    row.sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions
                ) {
                    let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                        from: analysisResults, in: row.sentence, candidateLookup: candidateLookup, hangulUsageLookup: { _ in 0 })
                    clauseFeatures = stableClauseContentFeatures(from: winningTokens)

                    let sessionInputsOn = session.scoringInputs

                    // Paired ON/OFF timing, randomized order (see the function doc comment).
                    // Only the ON call's result (`rerankedOn`) is used for ranking/commit below —
                    // identical to before this change; the OFF call here is measurement-only.
                    var rerankedOn: [HanjaSegment] = []
                    var onElapsedUs = 0.0
                    var offElapsedUs = 0.0

                    func timedOn() {
                        let ticks = mach_absolute_time()
                        rerankedOn = KiwiAnalysisService.applyContextReranking(
                            to: segments, clause: row.sentence, dominantMap: dominantMap,
                            candidateLookup: candidateLookup, winningTokens: winningTokens,
                            associationFeatureLookup: associationLookup, sessionInputs: sessionInputsOn
                        )
                        onElapsedUs = ticksToMicroseconds(mach_absolute_time() - ticks)
                    }
                    func timedOff() {
                        let ticks = mach_absolute_time()
                        _ = KiwiAnalysisService.applyContextReranking(
                            to: segments, clause: row.sentence, dominantMap: dominantMap,
                            candidateLookup: candidateLookup, winningTokens: winningTokens,
                            associationFeatureLookup: associationLookup, sessionInputs: nil
                        )
                        offElapsedUs = ticksToMicroseconds(mach_absolute_time() - ticks)
                    }

                    if Bool.random() {
                        timedOff()
                        timedOn()
                    } else {
                        timedOn()
                        timedOff()
                    }
                    latenciesOnUs.append(onElapsedUs)
                    latenciesOffUs.append(offElapsedUs)
                    latencyDeltasUs.append(onElapsedUs - offElapsedUs)

                    if row.role == "first" || row.role == "later" {
                        if let segmentIndex = segments.firstIndex(where: { $0.normalizedLookupKey == row.reading }) {
                            let rerankedSegment = rerankedOn[segmentIndex]
                            let candidates = candidateLookup(rerankedSegment.normalizedLookupKey)
                            let scores = associationScores(
                                for: candidates, contextFeatures: rerankedSegment.contextFeatures, lookup: associationLookup)
                            let sessionBoostsOn = sessionContextBoosts(
                                for: candidates, reading: rerankedSegment.normalizedLookupKey,
                                session: sessionInputsOn, lookup: associationLookup, weights: .default)

                            let rankedOnValues = rankWithContext(
                                candidates: candidates, contextDominantHanja: rerankedSegment.contextDominantHanja,
                                associationScores: scores, weights: .default, segmentTag: rerankedSegment.tag,
                                sessionBoosts: sessionBoostsOn
                            ).map(\.value)
                            let rankedOffValues = rankWithContext(
                                candidates: candidates, contextDominantHanja: rerankedSegment.contextDominantHanja,
                                associationScores: scores, weights: .default, segmentTag: rerankedSegment.tag,
                                sessionBoosts: [:]
                            ).map(\.value)

                            let rankOn = rankedOnValues.firstIndex(of: row.answer).map { $0 + 1 }
                            let rankOff = rankedOffValues.firstIndex(of: row.answer).map { $0 + 1 }

                            if rankOn == nil || rankOff == nil {
                                result.answerMiss += 1
                            } else if row.role == "first" {
                                firstSucceededForReading[row.reading] = true
                                result.firstOutcome.record(rankOn: rankOn, rankOff: rankOff)
                                selections = [(reading: row.reading, value: row.answer)]
                            } else {
                                let firstOK = firstSucceededForReading[row.reading] ?? false
                                let count = laterCountForReading[row.reading, default: 0]
                                laterCountForReading[row.reading] = count + 1
                                result.recordLater(
                                    rankOn: rankOn, rankOff: rankOff, reading: row.reading,
                                    firstSucceeded: firstOK, withinCap: count < laterCapPerDocumentReading)
                            }
                        } else {
                            if row.role == "first" {
                                result.firstSegMiss += 1
                                firstSucceededForReading[row.reading] = false
                            } else {
                                result.laterSegMiss += 1
                            }
                        }
                    }
                } else {
                    if row.role == "first" {
                        result.firstSegMiss += 1
                        firstSucceededForReading[row.reading] = false
                    } else if row.role == "later" {
                        result.laterSegMiss += 1
                    }
                }

                session.recordCommittedClause(features: clauseFeatures, selections: selections)
            }
        }

        return (result, latenciesOnUs, latenciesOffUs, latencyDeltasUs)
    }

    // MARK: - Task: R1c document/session replay

    func testSessionReplaySimulation() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping HanjaContextSessionReplayTests.")
            return
        }
        guard Self.kiwi != nil else {
            XCTFail("Kiwi failed to build from bundled models at \(Self.modelDir.path)")
            return
        }
        guard Self.hanjaTable != nil else {
            XCTFail("hanja.txt failed to load")
            return
        }
        XCTAssertFalse(Self.associationTable.isEmpty, "bundled hanja-context.txt must parse to a non-empty table")

        guard !Self.replayRows.isEmpty else {
            print("Session replay fixture not found or empty at eval/hanja-context-session-replay.tsv, skipping.")
            return
        }
        XCTAssertGreaterThanOrEqual(
            Self.replayRows.count, 1000,
            "session replay fixture must be non-trivially sized (got \(Self.replayRows.count) rows)"
        )

        let (result, latenciesOnUs, latenciesOffUs, latencyDeltasUs) = Self.replay(Self.replayRows)

        print(
            "REPLAY|docs=\(result.docCount) sentences=\(result.totalSentences) "
                + "segMiss=\(result.firstSegMiss + result.laterSegMiss) "
                + "(first=\(result.firstSegMiss) later=\(result.laterSegMiss)) answerMiss=\(result.answerMiss)"
        )

        let normalCapped = result.laterNormalCapped
        let normalUncapped = result.laterNormalUncapped
        print(
            "REPLAY|later on: top1 \(normalCapped.top1On)/\(normalCapped.n), top3 \(normalCapped.top3On)/\(normalCapped.n)"
                + " — off: top1 \(normalCapped.top1Off)/\(normalCapped.n), top3 \(normalCapped.top3Off)/\(normalCapped.n)"
                + " (capped=\(Self.laterCapPerDocumentReading)/doc·reading, first-succeeded bucket)"
        )
        print(
            "REPLAY|later uncapped on: top1 \(normalUncapped.top1On)/\(normalUncapped.n), top3 \(normalUncapped.top3On)/\(normalUncapped.n)"
                + " — off: top1 \(normalUncapped.top1Off)/\(normalUncapped.n), top3 \(normalUncapped.top3Off)/\(normalUncapped.n)"
        )

        let vocabCapped = result.laterVocabOnlyCapped
        let vocabUncapped = result.laterVocabOnlyUncapped
        print(
            "REPLAY|later vocabOnly(firstSegMiss) capped on: top1 \(vocabCapped.top1On)/\(vocabCapped.n)"
                + " — off: top1 \(vocabCapped.top1Off)/\(vocabCapped.n)"
        )
        print(
            "REPLAY|later vocabOnly(firstSegMiss) uncapped on: top1 \(vocabUncapped.top1On)/\(vocabUncapped.n)"
                + " — off: top1 \(vocabUncapped.top1Off)/\(vocabUncapped.n)"
        )

        print(
            "REPLAY|first on: top1 \(result.firstOutcome.top1On)/\(result.firstOutcome.n), top3 \(result.firstOutcome.top3On)/\(result.firstOutcome.n)"
                + " — off: top1 \(result.firstOutcome.top1Off)/\(result.firstOutcome.n), top3 \(result.firstOutcome.top3Off)/\(result.firstOutcome.n)"
        )

        // Paired ON/OFF latency (coordinator request, 2026-07-25): isolates "existing pipeline
        // cost for this clause" (OFF) from "R1 session axis marginal cost" (delta = ON - OFF, same
        // sentence, randomized measurement order — see the `replay` function's doc comment for why).
        let sortedOn = latenciesOnUs.sorted()
        let sortedOff = latenciesOffUs.sorted()
        let sortedDelta = latencyDeltasUs.sorted()
        let onP50 = Self.percentile(sortedOn, 0.5)
        let onP95 = Self.percentile(sortedOn, 0.95)
        let offP50 = Self.percentile(sortedOff, 0.5)
        let offP95 = Self.percentile(sortedOff, 0.95)
        let deltaP50 = Self.percentile(sortedDelta, 0.5)
        let deltaP95 = Self.percentile(sortedDelta, 0.95)
        print(
            "REPLAY|latency on p50=\(String(format: "%.2f", onP50))µs p95=\(String(format: "%.2f", onP95))µs"
                + " off p50=\(String(format: "%.2f", offP50))µs p95=\(String(format: "%.2f", offP95))µs"
                + " delta(on-off) p50=\(String(format: "%.2f", deltaP50))µs p95=\(String(format: "%.2f", deltaP95))µs"
                + " n=\(sortedOn.count)"
        )

        for reading in result.perReadingLaterCapped.keys.sorted() {
            let outcome = result.perReadingLaterCapped[reading]!
            print("REPLAY|series=\(reading) later_n=\(outcome.n) off_top1=\(outcome.top1Off) on_top1=\(outcome.top1On)")
        }

        // Assert (a) — spec §2: measured (capped) later pairs >= 100. Scope: the combined total of
        // both later buckets (normal + vocabOnly) — see the file-level doc comment's interpretation note.
        let combinedCappedN = normalCapped.n + vocabCapped.n
        XCTAssertGreaterThanOrEqual(
            combinedCappedN, 100,
            "measured (capped) later pairs must be >= 100 (got \(combinedCappedN): normal=\(normalCapped.n) vocabOnly=\(vocabCapped.n))"
        )

        // Assert (b) — spec §2: session ON later top1 >= OFF later top1 (ties allowed — session
        // must not HURT). Same combined scope as assert (a).
        let combinedTop1On = normalCapped.top1On + vocabCapped.top1On
        let combinedTop1Off = normalCapped.top1Off + vocabCapped.top1Off
        XCTAssertGreaterThanOrEqual(
            combinedTop1On, combinedTop1Off,
            "session ON must not regress later top1 vs OFF (on=\(combinedTop1On) off=\(combinedTop1Off))"
        )
    }
}
