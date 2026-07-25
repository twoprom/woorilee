// Step R2 (docs/plans/hanja-context-scaling-plan.md §7) — real-data integration tests for the
// clause-wide joint candidate selection stage.
//     Copyright (C) 2026 Seungjin Lee.
//
// RealtimeContextRankingTests.swift covers the joint stage's pure-logic invariants (self-exclusion,
// promotion-gate isolation, the maxSegments cap) against hand-built candidates/profiles. This file
// answers the one thing those stubs can't: whether the joint stage changes anything on REAL corpus
// data for a clause Kiwi actually segments into two target segments. Style mirrors
// HanjaContextSessionReplayTests.swift / HanjaContextEvalV2Tests.swift (static real Kiwi built
// directly from the repo's KiwiModels, hanja.txt, freq tables, hanja-context.txt — none of it via
// the app's warm-up singletons).
//
// Fixture derivation (coordinator + implementer, 2026-07-25): the coordinator's association-table
// scan flagged 수도(首都) x 정류(停留) — cos 0.1996, 51 shared features, no direct 수도/정류
// co-occurrence feature between them — as an R2-exclusive win candidate (docs/plans/
// hanja-context-scaling-plan.md §7 실측 표). "수도 요금" (the plan's own example) doesn't work —
// 요금 has no association row. The other flagged pair, 수도(修道) x 추기(樞機), turned out to be
// unreachable through Kiwi: "추기" is registered in KiwiModels/default.dict only as a low-score NNP
// stub ("추기\tNNP\t-10.0000") that `.joinNounSuffix` always folds into "추기경" (one token) in
// every natural sentence tried — never surfaces as a bare target segment. So this file uses
// 수도/정류 exclusively.
//
// A clause with ONLY 수도 and 정류 (e.g. "수도에서 정류한다") has ZERO direct association evidence
// either way (수도's top-3 by default order excludes 停留 entirely — it isn't even a candidate
// the joint search sees), so R1 and R2 agree trivially and prove nothing. To make R2's marginal
// contribution actually necessary, two extra real-corpus words were added, chosen so 정류's OWN
// (R1) association axis picks the WRONG domain by a razor-thin margin, and only R2's cross-profile
// bonus fixes it:
//   - "에너지/NNG" is a 정류:整流-only feature (weight 56, absent from 停留's profile).
//   - "아래/NNG" is a 정류:停留-only feature (weight 55, absent from 整流's profile).
// Both words are native/loanword nouns with NO hanja.txt entries of their own (verified via
// `candidateLookup` returning `[]`), so they can't accidentally trigger the UNRELATED step-4b
// containment axis (an earlier attempt using "정류장" as the boosting word did exactly that byaccident
// — 정류장's OWN dominant hanja 停留場 contains 停留 as a substring, so containment alone already
// decided the winner, defeating the point of isolating R2). With R1 alone (jointDomainConsistency
// forced to 0): 정류's own boost 整流(56) > 停留(55) by a 300-unit margin (in boost units, weight ×
// association 300) → 정류 picks 整流 — the WRONG domain relative to 수도's (unrelated, default)
// 首都. Only when R2 is enabled does cos(首都, 停留) × jointDomainConsistency(20) × association(300)
// ≈ 1197.8 get added to 停留's side, flipping it past 整流's raw lead — and only then do 수도/정류
// converge onto the SAME real-world domain (capital-city transit stop) that the coordinator's
// table predicted.
//
// `testJointConvergenceFixtureSegmentsAreReachedByKiwi` is the "먼저 짧은 실행 가능한 확인 코드로
// 분절이 실제로 2개 잡히는지 확인" step (spec §3.4 test #2) kept as a permanent regression check
// rather than thrown away, since the fixture sentence is load-bearing for the tests below it.

import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class RealtimeJointSelectionTests: XCTestCase {
    // MARK: - Shared fixtures (mirrors HanjaContextSessionReplayTests/HanjaContextEvalV2Tests —
    // deliberately NOT shared across files, so this file runs standalone via -only-testing)

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
        guard let text = try? String(contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja.txt"), encoding: .utf8) else {
            return [:]
        }
        return buildDominantHanjaMap(dictionaryLines: text.split(separator: "\n", omittingEmptySubsequences: true), frequency: freqTable.frequency(for:))
    }()

    /// Parsed directly from the repo's `.txt` (not the app-bundled `.bin`), mirroring
    /// HanjaContextSessionReplayTests/HanjaContextEvalV2Tests exactly — never
    /// `HanjaContextAssociationStore.shared`, so this file never depends on app warm-up ordering.
    private static let associationTable: [String: [String: [String: Double]]] = {
        let root = repoRoot()
        guard let contents = try? String(contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8) else {
            return [:]
        }
        return HanjaContextAssociationStore.parse(contents: contents)
    }()

    /// Mirrors HanjaContextEvalV2Tests.candidateLookup / HanjaContextSessionReplayTests.candidateLookup
    /// exactly (HanjaDictionaryService.exactCandidates(for:)'s numeric-first / dictionary-merge-with-
    /// empty-personalization contract) — duplicated rather than shared because it's `private` there.
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

    private static let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in
        associationTable[reading]?[hanja]
    }

    /// The fixture clause — see the file-level doc comment for how it was derived.
    private static let fixtureClause = "수도의 정류 에너지 아래"

    private static func analyzeFixture() throws -> (segments: [HanjaSegment], winningTokens: [Token]) {
        let kiwi = try XCTUnwrap(Self.kiwi, "Kiwi must build from bundled models at \(Self.modelDir.path)")
        let results = try kiwi.analyze(fixtureClause, topN: 1, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)
        return KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens(
            from: results, in: fixtureClause, candidateLookup: Self.candidateLookup, hangulUsageLookup: { _ in 0 }
        )
    }

    // MARK: - Preconditions

    /// Spec §3.4 test #2's "먼저 짧은 실행 가능한 확인 코드로 분절이 실제로 2개 잡히는지 확인"
    /// step, kept as a standing regression guard: if a future Kiwi/dictionary update stops
    /// segmenting the fixture this way, the convergence test below would silently stop meaning
    /// anything, so this pins the precondition explicitly.
    func testJointConvergenceFixtureSegmentsAreReachedByKiwi() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping RealtimeJointSelectionTests.")
            return
        }
        let (segments, _) = try Self.analyzeFixture()

        let sudo = try XCTUnwrap(segments.first { $0.normalizedLookupKey == "수도" })
        let jeongryu = try XCTUnwrap(segments.first { $0.normalizedLookupKey == "정류" })
        XCTAssertEqual(sudo.tag, .nng)
        XCTAssertEqual(jeongryu.tag, .nng)
        XCTAssertGreaterThanOrEqual(Self.candidateLookup("수도").count, 2)
        XCTAssertGreaterThanOrEqual(Self.candidateLookup("정류").count, 2)
        XCTAssertNil(NumericHanjaCandidateGenerator.normalizedDigits(from: "수도"))
        XCTAssertNil(NumericHanjaCandidateGenerator.normalizedDigits(from: "정류"))
    }

    // MARK: - Test #2: two-target-segment convergence (핵심 게이트 테스트)

    /// The headline R2 test: with the joint stage OFF (`jointDomainConsistency = 0` — also
    /// `HanjaContextRankingWeights.default` since the 2026-07-25 parking decision, see that
    /// property's doc comment), 정류 picks 整流 — R1's own association axis, by a 300-unit margin
    /// (56 vs 55, × association 300) picks the WRONG domain relative to 수도's (untouched, default)
    /// 首都. With the joint stage ON (`jointDomainConsistency = 20`, explicit — no longer the
    /// default), cos(首都, 停留) ≈ 0.1996's bonus (≈ 1197.8) overturns that margin and BOTH segments
    /// converge onto the real-world capital-transit domain the coordinator's association-profile
    /// scan predicted (수도(首都) × 정류(停留), 51 shared features, no DIRECT 수도/정류
    /// co-occurrence feature between them — see the file-level doc comment).
    func testJointStageConvergesSudoAndJeongryuOntoSameDomainOnlyWhenEnabled() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping RealtimeJointSelectionTests.")
            return
        }
        XCTAssertFalse(Self.associationTable.isEmpty, "bundled hanja-context.txt must parse to a non-empty table")

        let (segments, winningTokens) = try Self.analyzeFixture()

        // R2 is parked OFF by default (`HanjaContextRankingWeights.default.jointDomainConsistency
        // == 0`, 2026-07-25 user decision) — `jointOnWeights` builds the ON side explicitly at 20
        // (the value R2's own measurement used) rather than relying on `.default`.
        var jointOnWeights = HanjaContextRankingWeights.default
        jointOnWeights.jointDomainConsistency = 20
        var jointOffWeights = HanjaContextRankingWeights.default
        jointOffWeights.jointDomainConsistency = 0

        let rerankedOff = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: Self.fixtureClause, dominantMap: Self.dominantMap, candidateLookup: Self.candidateLookup,
            winningTokens: winningTokens, associationFeatureLookup: Self.associationLookup, weights: jointOffWeights
        )
        let rerankedOn = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: Self.fixtureClause, dominantMap: Self.dominantMap, candidateLookup: Self.candidateLookup,
            winningTokens: winningTokens, associationFeatureLookup: Self.associationLookup, weights: jointOnWeights
        )

        let sudoOff = try XCTUnwrap(rerankedOff.first { $0.normalizedLookupKey == "수도" })
        let jeongryuOff = try XCTUnwrap(rerankedOff.first { $0.normalizedLookupKey == "정류" })
        let sudoOn = try XCTUnwrap(rerankedOn.first { $0.normalizedLookupKey == "수도" })
        let jeongryuOn = try XCTUnwrap(rerankedOn.first { $0.normalizedLookupKey == "정류" })

        // OFF: R1 alone picks the mismatched domain pair (首都 water/capital reading, but 整流
        // electrical-rectification reading) — no convergence, and no joint bonus recorded anywhere.
        XCTAssertEqual(sudoOff.previewCandidate?.value, "首都")
        XCTAssertEqual(jeongryuOff.previewCandidate?.value, "整流", "sanity: without R2, R1's own evidence must pick the WRONG (non-converging) domain")
        XCTAssertTrue(sudoOff.jointBoosts.isEmpty)
        XCTAssertTrue(jeongryuOff.jointBoosts.isEmpty)

        // ON: R2 flips 정류 onto 停留 — the domain-consistent pairing with 수도's (unchanged) 首都.
        XCTAssertEqual(sudoOn.previewCandidate?.value, "首都")
        XCTAssertEqual(jeongryuOn.previewCandidate?.value, "停留", "R2 must converge 정류 onto 停留 to match 수도's 首都 domain")
        XCTAssertGreaterThan(sudoOn.jointBoosts["首都"] ?? 0, 0)
        XCTAssertGreaterThan(jeongryuOn.jointBoosts["停留"] ?? 0, 0)
    }

    /// Pins the 2026-07-25 parking decision (`HanjaContextRankingWeights.default.
    /// jointDomainConsistency == 0`, see that property's doc comment and
    /// `docs/plans/hanja-context-eval-baseline.md`'s "R2 클로즈 안 결합 선택 측정" §"파킹 결정"):
    /// plain `.default` weights must behave exactly like the explicit joint-axis-off path — empty
    /// `jointBoosts` on every segment, results byte-for-byte identical — even on `fixtureClause`,
    /// which IS genuinely joint-eligible (two participating segments, 수도/정류) and DOES converge
    /// onto a different answer when the axis is explicitly turned on (see the test right above).
    /// Without this test, a future default-value change could silently re-enable PASS 2 for
    /// production callers (which never pass `weights:` explicitly — see
    /// `KiwiAnalysisService.analyze`) without any test catching it.
    func testDefaultWeightsParkJointAxisOffEvenOnAJointEligibleClause() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping RealtimeJointSelectionTests.")
            return
        }
        XCTAssertFalse(Self.associationTable.isEmpty, "bundled hanja-context.txt must parse to a non-empty table")
        XCTAssertEqual(HanjaContextRankingWeights.default.jointDomainConsistency, 0, "sanity: the parked default must be 0")

        let (segments, winningTokens) = try Self.analyzeFixture()

        var jointOffWeights = HanjaContextRankingWeights.default
        jointOffWeights.jointDomainConsistency = 0

        let rerankedDefault = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: Self.fixtureClause, dominantMap: Self.dominantMap, candidateLookup: Self.candidateLookup,
            winningTokens: winningTokens, associationFeatureLookup: Self.associationLookup, weights: .default
        )
        let rerankedOff = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: Self.fixtureClause, dominantMap: Self.dominantMap, candidateLookup: Self.candidateLookup,
            winningTokens: winningTokens, associationFeatureLookup: Self.associationLookup, weights: jointOffWeights
        )

        XCTAssertTrue(rerankedDefault.allSatisfy { $0.jointBoosts.isEmpty }, "parked default must never populate jointBoosts, even on a joint-eligible clause")
        XCTAssertEqual(rerankedDefault, rerankedOff, "parked default must be byte-for-byte identical to the explicit joint-axis-off path")

        // Sanity: this really is the joint-eligible fixture, not a trivially-ineligible one — R1
        // alone still picks the non-converging answer (mirrors the OFF assertions above).
        let jeongryuDefault = try XCTUnwrap(rerankedDefault.first { $0.normalizedLookupKey == "정류" })
        XCTAssertEqual(jeongryuDefault.previewCandidate?.value, "整流", "sanity: with the parked default, 정류 must still pick R1's non-converging answer")
    }

    // MARK: - Test #6: candidate-panel consistency

    /// `HanjaServiceCoordinator.realtimeCandidates(for:)` can't be unit-tested directly (its
    /// `HanjaServiceCoordinator.shared` singleton has a private initializer and pulls in the whole
    /// app's warm-up graph — see HanjaContextEvalV2Tests's "PANEL ordering" comment for the same
    /// constraint), so this reproduces its documented algorithm exactly (docs/plans/
    /// hanja-context-scaling-plan.md §7 spec §3.3: fold `segment.jointBoosts` into the
    /// `sessionBoosts` map passed to `rankWithContext`, same-key sums) and asserts its `.first`
    /// matches the inline `previewCandidate` PASS 3 already committed to the segment.
    func testPanelOrderingTopCandidateMatchesInlinePreview() throws {
        guard Self.kiwiModelsAvailable else {
            print("Kiwi model directory not found at \(Self.modelDir.path), skipping RealtimeJointSelectionTests.")
            return
        }

        let (segments, winningTokens) = try Self.analyzeFixture()
        // R2 is parked OFF by default (`HanjaContextRankingWeights.default.jointDomainConsistency
        // == 0`) — this test is specifically about panel/preview consistency WHILE the joint stage
        // is active, so it must build weights explicitly rather than rely on `.default`.
        var jointOnWeights = HanjaContextRankingWeights.default
        jointOnWeights.jointDomainConsistency = 20
        let rerankedOn = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: Self.fixtureClause, dominantMap: Self.dominantMap, candidateLookup: Self.candidateLookup,
            winningTokens: winningTokens, associationFeatureLookup: Self.associationLookup, weights: jointOnWeights
        )

        for segment in rerankedOn where segment.normalizedLookupKey == "수도" || segment.normalizedLookupKey == "정류" {
            let candidates = Self.candidateLookup(segment.normalizedLookupKey)
            let scores = associationScores(for: candidates, contextFeatures: segment.contextFeatures, lookup: Self.associationLookup)

            // PANEL ordering — mirrors HanjaServiceCoordinator.realtimeCandidates(for:) exactly:
            // session boosts (none here) with the segment's jointBoosts folded in, same-key summed.
            var sessionBoosts: [String: Double] = [:]
            for (value, boost) in segment.jointBoosts {
                sessionBoosts[value, default: 0] += boost
            }

            let panelOrder = rankWithContext(
                candidates: candidates, contextDominantHanja: segment.contextDominantHanja,
                associationScores: scores, weights: .default, segmentTag: segment.tag, sessionBoosts: sessionBoosts
            )

            XCTAssertEqual(panelOrder.first?.value, segment.previewCandidate?.value, "panel top-1 must match the inline preview for \(segment.surface)")
        }
    }
}
