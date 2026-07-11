// Step 5d 평가·튜닝 — real-Kiwi runner for the v1+v2 eval set against the step-5 corpus
// association table.
//     Copyright (C) 2026 Seungjin Lee.
//
// Unlike HanjaContextEvalTests (Kiwi-free, eojeol-prefix approximation), this file drives the
// PRODUCTION realtime pipeline end to end: Kiwi analysis (KiwiAnalysisService.bestRealtimeSegments-
// WithWinningTokens) -> KiwiAnalysisService.applyContextReranking -> the panel ordering computed
// exactly as HanjaServiceCoordinator.realtimeCandidates(for:) does. It measures two configurations
// — association OFF (the step-4b containment-only baseline) and association ON (step-5c, with the
// real bundled hanja-context.txt) — against both the 195 v1 rows and the v2 native-context rows
// appended in eval/hanja-context-eval-set.tsv (see docs/plans/context-aware-hanja-conversion.md §7
// 5d). Kiwi, the hanja dictionary, and the association table are all loaded directly from the repo
// files here (NOT the app's warm-up singletons) so this test never depends on warm-up ordering.
//
// Self-skips (prints and returns) if the Kiwi model directory is missing, mirroring the pattern in
// KiwiOfflinePipelineConsistencyTests.

import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextEvalV2Tests: XCTestCase {
    private struct EvalRow { let sentence: String; let reading: String; let answer: String }

    private struct EvalOutcome {
        var n = 0
        var top1 = 0
        var top3 = 0
        var segMiss = 0
        var segMissRows: [String] = []
        var flagshipRank: Int?
        var perSeries: [String: (n: Int, top1: Int)] = [:]
        /// Per-row (sentence, reading, answer, rank) detail — used by the small v3 subset (step
        /// 7d) for row-level pass/fail diagnostics. Additive only; does not affect v1/v2 stats.
        var perRow: [(row: EvalRow, rank: Int?)] = []

        /// Rows that produced a rankable segment — segMiss rows are excluded from the top1/top3
        /// denominators (they are reported separately).
        var scored: Int { n - segMiss }
    }

    // MARK: - Shared fixtures (computed once for the whole test run, like production warm-up)

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

    /// Association table parsed directly from the repo file via the nonisolated static parser —
    /// deliberately NOT HanjaContextAssociationStore.shared, so this test never depends on the
    /// app's warm-up sequence.
    private static let associationTable: [String: [String: [String: UInt8]]] = {
        let root = repoRoot()
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8)
        else {
            return [:]
        }
        return HanjaContextAssociationStore.parse(contents: contents)
    }()

    /// v3 (step 7d, docs/plans/context-aware-hanja-conversion.md §10 7d) is parsed as a THIRD
    /// section, delimited by its own "# ---- v3" marker after the v2 section — it must never fold
    /// into `v2` (that would silently change the v2 subset's row count / off-on percentages that
    /// are pinned as the step-5d baseline: 53/55). v1/v2 parsing itself is unchanged from before
    /// step 7d.
    private static let rows: (v1: [EvalRow], v2: [EvalRow], v3: [EvalRow]) = {
        let url = repoRoot().appendingPathComponent("eval/hanja-context-eval-set.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], [], []) }

        var v1: [EvalRow] = []
        var v2: [EvalRow] = []
        var v3: [EvalRow] = []
        enum Section { case v1, v2, v3 }
        var section = Section.v1
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ---- v3") {
                section = .v3
                continue
            }
            if line.hasPrefix("# ---- v2") {
                section = .v2
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 3, !c[0].isEmpty, !c[1].isEmpty, !c[2].isEmpty else { continue }
            let row = EvalRow(sentence: c[0], reading: c[1], answer: c[2])
            switch section {
            case .v1: v1.append(row)
            case .v2: v2.append(row)
            case .v3: v3.append(row)
            }
        }
        return (v1, v2, v3)
    }()

    /// Mirrors HanjaDictionaryService.exactCandidates(for:) (numeric-first, then dictionary lookup
    /// merged with empty user/usage tables — reading-only, no personalization) exactly as
    /// KiwiAnalysisService.analyzeClause's candidateLookup does.
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

    private static func pct(_ a: Int, _ b: Int) -> String {
        b == 0 ? "0%" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b))
    }

    /// Runs the production realtime pipeline (Kiwi analysis -> bestRealtimeSegmentsWithWinningTokens
    /// -> applyContextReranking) over `rows`, then computes the PANEL ordering for the segment
    /// matching each row's target reading exactly as HanjaServiceCoordinator.realtimeCandidates(for:)
    /// does, and reports the rank of the expected answer within that panel order.
    private static func evaluate(rows: [EvalRow], useAssociation: Bool) -> EvalOutcome {
        var outcome = EvalOutcome()
        guard let kiwi else { return outcome }

        let associationLookup: ((String, String) -> [String: UInt8]?)? = useAssociation
            ? { reading, hanja in associationTable[reading]?[hanja] }
            : nil

        for row in rows {
            outcome.n += 1

            guard let results = try? kiwi.analyze(
                row.sentence, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
            else {
                outcome.segMiss += 1
                outcome.segMissRows.append("\(row.reading)/\(row.answer) :: \(row.sentence)")
                continue
            }

            let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
                from: results, in: row.sentence, candidateLookup: candidateLookup, hangulUsageLookup: { _ in 0 })

            guard let segmentIndex = segments.firstIndex(where: { $0.normalizedLookupKey == row.reading }) else {
                outcome.segMiss += 1
                outcome.segMissRows.append("\(row.reading)/\(row.answer) :: \(row.sentence)")
                continue
            }

            let reranked = KiwiAnalysisService.applyContextReranking(
                to: segments, clause: row.sentence, dominantMap: dominantMap,
                candidateLookup: candidateLookup, winningTokens: winningTokens,
                associationFeatureLookup: associationLookup
            )
            let segment = reranked[segmentIndex]

            // PANEL ordering — mirrors HanjaServiceCoordinator.realtimeCandidates(for:) exactly:
            // full candidate list, re-ranked with the segment's carried context + association scores.
            let candidates = candidateLookup(segment.normalizedLookupKey)
            let scores = associationLookup.map {
                associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: $0)
            } ?? [:]
            let rankedValues = rankWithContext(
                candidates: candidates, contextDominantHanja: segment.contextDominantHanja,
                associationScores: scores, weights: .default
            ).map(\.value)
            let rank = rankedValues.firstIndex(of: row.answer).map { $0 + 1 }
            outcome.perRow.append((row: row, rank: rank))

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

    // MARK: - Task 2: real-Kiwi eval + gates

    func testEval5DAssociationRanking() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping HanjaContextEvalV2Tests.")
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

        let v1 = Self.rows.v1
        let v2 = Self.rows.v2
        let v3 = Self.rows.v3
        XCTAssertGreaterThanOrEqual(v1.count, 195, "v1 must retain its 195 rows")
        XCTAssertGreaterThanOrEqual(v2.count, 40, "v2 native-context rows must be present")
        XCTAssertGreaterThanOrEqual(v3.count, 6, "v3 native-homograph-gate rows must be present (step 7d)")

        let offV1 = Self.evaluate(rows: v1, useAssociation: false)
        let onV1 = Self.evaluate(rows: v1, useAssociation: true)
        let offV2 = Self.evaluate(rows: v2, useAssociation: false)
        let onV2 = Self.evaluate(rows: v2, useAssociation: true)
        // v3 (step 7d) is measured but NOT gated here — the plan explicitly separates ranking
        // measurement (this harness) from the awaitsContextEvidence promotion/suppression
        // decision, which is pinned by dedicated unit/integration tests instead (see
        // RealtimeNativeHomographGateTests and HanjaContextNativeHomographIntegrationTests). A
        // row that ranks below 1 here reflects a real feature gap, not a harness bug — reported,
        // not doctored.
        let onV3 = Self.evaluate(rows: v3, useAssociation: true)

        print("EVAL5D|config=off|v1 top1=\(offV1.top1)/\(offV1.scored) (\(Self.pct(offV1.top1, offV1.scored))) top3=\(offV1.top3)/\(offV1.scored) segMiss=\(offV1.segMiss)")
        print("EVAL5D|config=on|v1 top1=\(onV1.top1)/\(onV1.scored) (\(Self.pct(onV1.top1, onV1.scored))) top3=\(onV1.top3)/\(onV1.scored) segMiss=\(onV1.segMiss)")
        print("EVAL5D|config=off|v2 top1=\(offV2.top1)/\(offV2.scored) (\(Self.pct(offV2.top1, offV2.scored))) top3=\(offV2.top3)/\(offV2.scored) segMiss=\(offV2.segMiss)")
        print("EVAL5D|config=on|v2 top1=\(onV2.top1)/\(onV2.scored) (\(Self.pct(onV2.top1, onV2.scored))) top3=\(onV2.top3)/\(onV2.scored) segMiss=\(onV2.segMiss)")
        print("EVAL5D|flagship rank=\(onV2.flagshipRank.map(String.init) ?? "notFound") config=on")
        print("EVAL5D|flagship rank=\(offV2.flagshipRank.map(String.init) ?? "notFound") config=off")
        for miss in onV1.segMissRows { print("EVAL5D|segMiss v1 \(miss)") }
        for miss in onV2.segMissRows { print("EVAL5D|segMiss v2 \(miss)") }

        for series in onV2.perSeries.keys.sorted() {
            let on = onV2.perSeries[series]!
            let off = offV2.perSeries[series] ?? (n: 0, top1: 0)
            print("EVAL5D|series=\(series) n=\(on.n) off_top1=\(off.top1) on_top1=\(on.top1)")
        }

        print("EVAL7D|config=on|v3 top1=\(onV3.top1)/\(onV3.scored) (\(Self.pct(onV3.top1, onV3.scored))) top3=\(onV3.top3)/\(onV3.scored) segMiss=\(onV3.segMiss)")
        for miss in onV3.segMissRows { print("EVAL7D|segMiss v3 \(miss)") }
        for (row, rank) in onV3.perRow {
            print("EVAL7D|row reading=\(row.reading) answer=\(row.answer) rank=\(rank.map(String.init) ?? "notFound") :: \(row.sentence)")
        }

        // Gate 1 — v1: association ON must not regress top1 vs OFF.
        XCTAssertGreaterThanOrEqual(
            onV1.top1, offV1.top1,
            "association must not regress v1 top1 (off=\(offV1.top1) on=\(onV1.top1))"
        )

        // Gate 2 — v2 native-context subset: association ON must improve top1 by >= 20pp over OFF.
        let offV2Pct = offV2.scored == 0 ? 0.0 : 100.0 * Double(offV2.top1) / Double(offV2.scored)
        let onV2Pct = onV2.scored == 0 ? 0.0 : 100.0 * Double(onV2.top1) / Double(onV2.scored)
        XCTAssertGreaterThanOrEqual(
            onV2Pct - offV2Pct, 20.0,
            "association must improve v2 native-context top1 by >= 20pp (off=\(offV2Pct)% on=\(onV2Pct)%)"
        )

        // Gate 3 — flagship: 水道 must rank first under association ON.
        XCTAssertEqual(onV2.flagshipRank, 1, "\"우리 집 수도가 얼었다\" must rank 水道 first under association ON")
    }

    // MARK: - Task 3: latency + warmup

    /// Per-keystroke cost: applyContextReranking on a representative clause (~15 morphemes, 2-3
    /// convertible segments) with the real bundled association data.
    func testApplyContextRerankingLatency() throws {
        guard Self.kiwiModelsAvailable, let kiwi = Self.kiwi, Self.hanjaTable != nil else {
            print("Kiwi model directory not found, skipping latency measurement.")
            return
        }
        XCTAssertFalse(Self.associationTable.isEmpty)

        let clause = "정수 필터를 새로 달았더니 수도에서 나오는 물이 훨씬 깨끗해지고 냄새도 사라졌다."
        let results = try kiwi.analyze(clause, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        let (segments, winningTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
            from: results, in: clause, candidateLookup: Self.candidateLookup, hangulUsageLookup: { _ in 0 })
        XCTAssertGreaterThanOrEqual(
            segments.filter(\.isConvertible).count, 2,
            "representative clause must have 2-3 convertible segments"
        )

        let associationLookup: (String, String) -> [String: UInt8]? = { reading, hanja in
            Self.associationTable[reading]?[hanja]
        }

        // Force the lazy static fixtures (association table parse, dominant map) to materialize
        // BEFORE measuring, so the first measure iteration reflects per-keystroke cost only.
        _ = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: clause, dominantMap: Self.dominantMap,
            candidateLookup: Self.candidateLookup, winningTokens: winningTokens,
            associationFeatureLookup: associationLookup
        )

        measure {
            _ = KiwiAnalysisService.applyContextReranking(
                to: segments, clause: clause, dominantMap: Self.dominantMap,
                candidateLookup: Self.candidateLookup, winningTokens: winningTokens,
                associationFeatureLookup: associationLookup
            )
        }
    }

    /// Confirms applyContextReranking scales roughly linearly in CONTEXT SIZE (the "문맥 형태소 수"
    /// axis of the plan's O(후보 K × 문맥 형태소 수) requirement): with the segment list, clause,
    /// and candidate sets held CONSTANT, doubling only the context-token count must roughly double
    /// — not roughly quadruple — the wall-clock cost. (Comparing two clauses of different lengths
    /// would conflate this with segment count: the per-segment self-exclusion pass is O(segments ×
    /// tokens) by design, so total clause cost grows superlinearly in clause LENGTH while staying
    /// linear in context size per segment — which is what this test pins.)
    func testApplyContextRerankingScalesLinearlyWithContextTokenCount() throws {
        guard Self.kiwiModelsAvailable, let kiwi = Self.kiwi, Self.hanjaTable != nil else {
            print("Kiwi model directory not found, skipping scaling check.")
            return
        }

        let clause = "정수 필터를 새로 달았더니 수도에서 나오는 물이 훨씬 깨끗해졌다."
        let results = try kiwi.analyze(clause, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        let (segments, realTokens) = KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
            from: results, in: clause, candidateLookup: Self.candidateLookup, hangulUsageLookup: { _ in 0 })
        let associationLookup: (String, String) -> [String: UInt8]? = { reading, hanja in
            Self.associationTable[reading]?[hanja]
        }

        // Synthetic distinct content-morpheme tokens (unique forms so feature dedup keeps them
        // all), positioned past the clause end so they never overlap any segment's sourceRange.
        func syntheticTokens(count: Int) -> [Token] {
            let base = inputUTF16Length(of: clause) + 10
            return (0..<count).map { i in
                Token(form: "합성문맥\(i)", tag: .nng, position: base + i * 4, length: 2)
            }
        }

        // Total context tokens: 1x = realContext + B synthetic = 2B; 2x = realContext + 3B = 4B.
        let baseContextCount = realTokens.filter { KiwiAnalysisService.isContextContentMorphemeTag($0.tag) }.count
        let tokens1x = realTokens + syntheticTokens(count: baseContextCount)
        let tokens2x = realTokens + syntheticTokens(count: 3 * baseContextCount)

        func timePerRun(winningTokens: [Token], iterations: Int) -> Double {
            let start = Date()
            for _ in 0..<iterations {
                _ = KiwiAnalysisService.applyContextReranking(
                    to: segments, clause: clause, dominantMap: Self.dominantMap,
                    candidateLookup: Self.candidateLookup, winningTokens: winningTokens,
                    associationFeatureLookup: associationLookup
                )
            }
            return Date().timeIntervalSince(start) / Double(iterations)
        }

        // Warm caches once, then measure.
        _ = timePerRun(winningTokens: tokens1x, iterations: 50)
        let iterations = 500
        let seconds1x = timePerRun(winningTokens: tokens1x, iterations: iterations)
        let seconds2x = timePerRun(winningTokens: tokens2x, iterations: iterations)
        let ratio = seconds1x > 0 ? seconds2x / seconds1x : 0

        print("EVAL5D|scaling context1x_ms=\(String(format: "%.4f", seconds1x * 1000)) context2x_ms=\(String(format: "%.4f", seconds2x * 1000)) ratio=\(String(format: "%.2f", ratio))")

        // 2x context tokens should cost ~2x (linear), not ~4x (quadratic). Generous upper bound to
        // absorb measurement noise while still catching a genuine quadratic blowup.
        XCTAssertLessThan(ratio, 3.5, "doubling the context-token count should roughly double, not quadruple, the cost (ratio=\(ratio))")
    }

    /// Warm-up cost: HanjaContextAssociationStore.parse on the real bundled file (runs off-main in
    /// production, see HanjaContextAssociationStore.warmUp).
    func testAssociationStoreParseWarmUpDuration() throws {
        let path = Self.repoRoot().appendingPathComponent("woorilee/data/hanja/hanja-context.txt")
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("hanja-context.txt missing at \(path.path)")
            return
        }

        let start = Date()
        let table = HanjaContextAssociationStore.parse(contents: contents)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(table.isEmpty)
        print("EVAL5D|warmup parse_seconds=\(String(format: "%.3f", elapsed)) readings=\(table.count)")
    }
}
