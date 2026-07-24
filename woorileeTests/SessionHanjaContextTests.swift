// Tests for step R1a: session vocabulary buffer and last-committed selection priors.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/hanja-context-scaling-plan.md §6 (R1a). Six groups, per the R1a implementation
// spec §10: (1) HanjaSessionContext unit, (2) sessionContextBoosts unit, (3) rankWithContext +
// sessionBoosts, (4) applyContextReranking + sessionInputs, (5) InputSession integration
// (FakeIMKTextInput + InputCompositionEngine), (6) session-on latency — that last group lives next
// to HanjaContextEvalV2Tests.testApplyContextRerankingLatency instead, per the spec's own §12
// exception for that one addition.

import AppKit
import InputMethodKit
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class SessionHanjaContextTests: XCTestCase {
    // MARK: - Group 1: HanjaSessionContext unit

    func testTwentyFirstSentenceEvictsTheOldest() {
        var context = HanjaSessionContext()
        for index in 0..<21 {
            context.recordCommittedClause(features: ["형태소\(index)/NNG"], selections: [])
        }

        let vocabulary = context.scoringInputs.vocabularyFeatures
        XCTAssertEqual(vocabulary.count, 20)
        XCTAssertFalse(vocabulary.contains("형태소0/NNG"), "oldest sentence (index 0) must be evicted")
        XCTAssertTrue(vocabulary.contains("형태소1/NNG"))
        XCTAssertTrue(vocabulary.contains("형태소20/NNG"))
    }

    func testMorphemeCapEvictsOldestSentenceEvenUnderSentenceCap() {
        var context = HanjaSessionContext()
        // 10 sentences x 50 unique features = 500 morphemes > 400, but only 10 sentences (<= 20).
        // Eviction must happen on the MORPHEME cap alone here.
        for sentenceIndex in 0..<10 {
            let features = (0..<50).map { "s\(sentenceIndex)_f\($0)/NNG" }
            context.recordCommittedClause(features: features, selections: [])
        }

        let vocabulary = context.scoringInputs.vocabularyFeatures
        XCTAssertEqual(vocabulary.count, 400, "must evict oldest sentences until under the 400-morpheme cap")
        XCTAssertFalse(vocabulary.contains("s0_f0/NNG"), "oldest sentence (index 0) must be evicted")
        XCTAssertFalse(vocabulary.contains("s1_f0/NNG"), "second-oldest sentence (index 1) must also be evicted")
        XCTAssertTrue(vocabulary.contains("s2_f0/NNG"), "third-oldest sentence must survive")
        XCTAssertTrue(vocabulary.contains("s9_f49/NNG"), "newest sentence must survive")
    }

    func testSelectionPriorDecayValuesAndRemovalAtLifetime() {
        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "수도", value: "修道")])
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 1.0, accuracy: 1e-9)

        for _ in 0..<10 {
            context.recordCommittedClause(features: [], selections: [])
        }
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 0.5, accuracy: 1e-9, "age 10 of 20 -> decay 0.5")

        for _ in 0..<9 {
            context.recordCommittedClause(features: [], selections: [])
        }
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 0.05, accuracy: 1e-9, "age 19 of 20 -> decay 0.05")
        XCTAssertNotNil(context.scoringInputs.selectionPriors["수도"], "must still be alive at age 19")

        context.recordCommittedClause(features: [], selections: [])
        XCTAssertNil(context.scoringInputs.selectionPriors["수도"], "age 20 must be evicted")
    }

    func testEmptyFeatureCommitStillAgesSelectionPriors() {
        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "수도", value: "首都")])
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 1.0, accuracy: 1e-9)

        // Empty-features commit: no sentence appended, but the aging clock still ticks.
        context.recordCommittedClause(features: [], selections: [])

        XCTAssertTrue(context.scoringInputs.vocabularyFeatures.isEmpty, "empty-feature commits must not add a sentence")
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 0.95, accuracy: 1e-9, "age 1 of 20 -> decay 0.95")
    }

    func testRecordManualSelectionReplacesAtAgeZeroWithoutAgingOthers() {
        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "수도", value: "首都")])
        for _ in 0..<5 {
            context.recordCommittedClause(features: [], selections: [])
        }
        XCTAssertEqual(context.scoringInputs.selectionPriors["수도"]?.decay ?? -1, 0.75, accuracy: 1e-9, "age 5 of 20 -> decay 0.75")

        context.recordManualSelection(reading: "수도", value: "修道")

        let prior = context.scoringInputs.selectionPriors["수도"]
        XCTAssertEqual(prior?.value, "修道", "manual selection must replace the value")
        XCTAssertEqual(prior?.decay ?? -1, 1.0, accuracy: 1e-9, "manual selection must reset age to 0")
    }

    func testValueEqualToReadingIsIgnoredByBothRecordingPaths() {
        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "한글", value: "한글")])
        XCTAssertNil(context.scoringInputs.selectionPriors["한글"], "hangul-kept fallback must not be recorded")

        context.recordManualSelection(reading: "한글", value: "한글")
        XCTAssertNil(context.scoringInputs.selectionPriors["한글"])
    }

    // MARK: - Group 2: sessionContextBoosts unit

    private func sudoCandidatesByFrequency() -> [HanjaCandidate] {
        [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]
    }

    func testSessionContextBoostsSelectionPriorAppliesOnlyToItsValue() {
        let session = HanjaSessionScoringInputs(
            vocabularyFeatures: [],
            selectionPriors: ["수도": HanjaSessionSelectionPrior(value: "修道", decay: 0.5)],
            isEmpty: false
        )

        let boosts = sessionContextBoosts(
            for: sudoCandidatesByFrequency(),
            reading: "수도",
            session: session,
            lookup: nil,
            weights: .default
        )

        XCTAssertEqual(boosts, ["修道": 10_000_000 * 0.5])
    }

    func testSessionContextBoostsVocabularyAxisScaledByAssociationAndSessionScale() {
        let session = HanjaSessionScoringInputs(
            vocabularyFeatures: ["집/NNG"],
            selectionPriors: [:],
            isEmpty: false
        )
        let lookup: (String, String) -> [String: Double]? = { reading, hanja in
            guard reading == "수도", hanja == "水道" else { return nil }
            return ["집/NNG": 37]
        }

        let boosts = sessionContextBoosts(
            for: sudoCandidatesByFrequency(),
            reading: "수도",
            session: session,
            lookup: lookup,
            weights: .default
        )

        XCTAssertEqual(boosts.count, 1)
        XCTAssertEqual(boosts["水道"] ?? 0, 37 * 300 * 0.5, accuracy: 1e-9)
    }

    /// R1a perf fix (조율자 2단계, docs/plans/hanja-context-scaling-plan.md §6): the clause-feature
    /// dedup was removed from `sessionContextBoosts` for performance — a feature counted by BOTH
    /// the in-clause association axis (1.0×) and the session vocabulary axis (0.5×) now
    /// contributes to both, summing to a 1.5× ceiling for that single matched feature. This pins
    /// the exact combined math so a future change doesn't silently alter it.
    func testSessionAndClauseAxesDoubleCountAFeaturePresentInBoth() {
        let candidates = sudoCandidatesByFrequency()
        let lookup: (String, String) -> [String: Double]? = { reading, hanja in
            guard reading == "수도", hanja == "水道" else { return nil }
            return ["집/NNG": 37]
        }

        // The in-clause axis (existing associationScores, unchanged by this fix).
        let clauseScores = associationScores(for: candidates, contextFeatures: ["집/NNG"], lookup: lookup)
        let clauseContribution = (clauseScores["水道"] ?? 0) * Double(HanjaContextRankingWeights.default.association)

        // The session axis: same feature, same lookup, no exclusion of clause-shared features.
        let session = HanjaSessionScoringInputs(vocabularyFeatures: ["집/NNG"], selectionPriors: [:], isEmpty: false)
        let sessionBoosts = sessionContextBoosts(
            for: candidates, reading: "수도", session: session, lookup: lookup, weights: .default
        )
        let sessionContribution = sessionBoosts["水道"] ?? 0

        let fullWeight = 37.0 * 300.0
        XCTAssertEqual(clauseContribution, fullWeight, accuracy: 1e-9)
        XCTAssertEqual(sessionContribution, fullWeight * 0.5, accuracy: 1e-9)
        XCTAssertEqual(
            clauseContribution + sessionContribution, fullWeight * 1.5, accuracy: 1e-9,
            "a feature present in both clause and session vocabulary must sum to a 1.5x ceiling"
        )
    }

    func testSessionContextBoostsWithNilLookupOnlyAppliesSelectionPrior() {
        let session = HanjaSessionScoringInputs(
            vocabularyFeatures: ["집/NNG"],
            selectionPriors: ["수도": HanjaSessionSelectionPrior(value: "首都", decay: 1.0)],
            isEmpty: false
        )

        let boosts = sessionContextBoosts(
            for: sudoCandidatesByFrequency(),
            reading: "수도",
            session: session,
            lookup: nil,
            weights: .default
        )

        XCTAssertEqual(boosts, ["首都": 10_000_000])
    }

    func testSessionAssociationScoresSumsOnlyEntriesInVocabularySet() {
        let candidates = sudoCandidatesByFrequency()
        let lookup: (String, String) -> [String: Double]? = { reading, hanja in
            guard reading == "수도" else { return nil }
            switch hanja {
            case "首都": return ["서울/NNP": 10, "행정/NNG": 5]
            case "水道": return ["집/NNG": 37, "누수/NNG": 12]
            default: return nil
            }
        }

        let scores = sessionAssociationScores(for: candidates, vocabulary: ["집/NNG"], lookup: lookup)

        XCTAssertEqual(scores, ["水道": 37])
    }

    func testSessionAssociationScoresWithEmptyVocabularyReturnsEmpty() {
        let scores = sessionAssociationScores(
            for: sudoCandidatesByFrequency(), vocabulary: [], lookup: { _, _ in ["집/NNG": 37] }
        )
        XCTAssertTrue(scores.isEmpty)
    }

    func testSessionContextBoostsWithEmptySessionReturnsEmptyDictionary() {
        let emptySession = HanjaSessionScoringInputs(vocabularyFeatures: [], selectionPriors: [:], isEmpty: true)

        let boosts = sessionContextBoosts(
            for: sudoCandidatesByFrequency(),
            reading: "수도",
            session: emptySession,
            lookup: { _, _ in ["집/NNG": 37] },
            weights: .default
        )

        XCTAssertTrue(boosts.isEmpty)
    }

    // MARK: - Group 3: rankWithContext + sessionBoosts

    func testRankWithContextSessionBoostPromotesSelectedCandidateToFirst() {
        let ranked = rankWithContext(
            candidates: sudoCandidatesByFrequency(),
            contextDominantHanja: [],
            weights: .default,
            sessionBoosts: ["修道": 10_000_000]
        )

        XCTAssertEqual(ranked.first?.value, "修道")
    }

    func testRankWithContextEmptySessionBoostsIsIdenticalToOmittedParameter() {
        let candidates = sudoCandidatesByFrequency()

        let withoutParameter = rankWithContext(candidates: candidates, contextDominantHanja: [], weights: .default)
        let withEmptyBoosts = rankWithContext(
            candidates: candidates, contextDominantHanja: [], weights: .default, sessionBoosts: [:]
        )

        XCTAssertEqual(withoutParameter.map(\.value), withEmptyBoosts.map(\.value))
    }

    // MARK: - Group 4: applyContextReranking + sessionInputs

    private func sudoLookup(_ key: String) -> [HanjaCandidate] {
        key == "수도" ? sudoCandidatesByFrequency() : []
    }

    private func singleSudoSegment(previewValue: String = "首都") -> HanjaSegment {
        let candidate = sudoCandidatesByFrequency().first { $0.value == previewValue }
        return HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2),
            surface: "수도",
            normalizedLookupKey: "수도",
            tag: .nng,
            isConvertible: true,
            previewCandidate: candidate
        )
    }

    func testApplyContextRerankingWithNilOrEmptySessionInputsMatchesOmittedParameter() {
        let segments = [singleSudoSegment()]

        let omitted = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: "수도", dominantMap: [:], candidateLookup: sudoLookup(_:)
        )
        let explicitNil = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: "수도", dominantMap: [:], candidateLookup: sudoLookup(_:), sessionInputs: nil
        )
        let emptySession = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: "수도", dominantMap: [:], candidateLookup: sudoLookup(_:),
            sessionInputs: HanjaSessionContext().scoringInputs
        )

        XCTAssertEqual(omitted, segments)
        XCTAssertEqual(omitted, explicitNil)
        XCTAssertEqual(omitted, emptySession)
    }

    func testApplyContextRerankingSelectionPriorFlipsNonGatedSegmentPreview() throws {
        let segments = [singleSudoSegment()] // baseline preview: 首都 (frequency leader)
        XCTAssertEqual(segments[0].previewCandidate?.value, "首都")

        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "수도", value: "修道")])

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: "수도", dominantMap: [:], candidateLookup: sudoLookup(_:),
            sessionInputs: context.scoringInputs
        )

        let waterway = try XCTUnwrap(reranked.first { $0.surface == "수도" })
        XCTAssertEqual(waterway.previewCandidate?.value, "修道", "session selection prior must flip the preview")
    }

    func testApplyContextRerankingPromotionInvariantSessionEvidenceAloneDoesNotPromote() throws {
        // Hand-built awaitsContextEvidence segment (native-homograph gate suppressed its preview),
        // with zero clause-level context/association evidence — only a session selection prior.
        let candidates = [
            HanjaCandidate(reading: "고장", value: "故障", comment: "", source: .system, usageCount: 0, frequency: 7492, baseRank: 0),
            HanjaCandidate(reading: "고장", value: "姑藏", comment: "", source: .system, usageCount: 0, frequency: 10, baseRank: 1),
        ]
        let segment = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2),
            surface: "고장",
            normalizedLookupKey: "고장",
            tag: .nng,
            isConvertible: true,
            previewCandidate: nil,
            awaitsContextEvidence: true
        )

        var context = HanjaSessionContext()
        context.recordCommittedClause(features: [], selections: [(reading: "고장", value: "故障")])

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: [segment], clause: "고장", dominantMap: [:],
            candidateLookup: { $0 == "고장" ? candidates : [] },
            sessionInputs: context.scoringInputs
        )

        let result = try XCTUnwrap(reranked.first)
        XCTAssertNil(result.previewCandidate, "session-only evidence must not promote an awaitsContextEvidence segment")
    }

    func testApplyContextRerankingSessionVocabularyFlipsRankingAtHalfWeight() throws {
        // A close frequency gap (100) that a full-weight in-clause association hit (300) would
        // clear, but which the session's 0.5x-scaled axis clears too when the matched weight (1)
        // is itself large enough: 1 * 300 * 0.5 = 150 > 100.
        let candidates = [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 3000, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2900, baseRank: 1),
        ]
        let segment = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2),
            surface: "수도",
            normalizedLookupKey: "수도",
            tag: .nng,
            isConvertible: true,
            previewCandidate: candidates[0] // 首都, the pre-session baseline
        )

        var context = HanjaSessionContext()
        context.recordCommittedClause(features: ["학교/NNG"], selections: [])

        let associationLookup: (String, String) -> [String: Double]? = { reading, hanja in
            guard reading == "수도", hanja == "修道" else { return nil }
            return ["학교/NNG": 1]
        }

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: [segment], clause: "수도", dominantMap: [:],
            candidateLookup: { $0 == "수도" ? candidates : [] },
            associationFeatureLookup: associationLookup,
            sessionInputs: context.scoringInputs
        )

        let result = try XCTUnwrap(reranked.first)
        XCTAssertEqual(result.previewCandidate?.value, "修道", "session vocabulary alone must be able to flip a close ranking")
    }

    // MARK: - Group 5: InputSession integration (FakeIMKTextInput + InputCompositionEngine)

    private func makeCommitHarness(
        rawText: String,
        previewValue: String,
        clauseContentFeatures: [String]
    ) -> (session: InputSession, engine: InputCompositionEngine, client: FakeIMKTextInput) {
        let client = FakeIMKTextInput()
        let session = InputSession()
        let candidate = HanjaCandidate(
            reading: rawText, value: previewValue, comment: "", source: .system,
            usageCount: 0, frequency: 0, baseRank: 0
        )
        let segment = HanjaSegment(
            sourceRange: NSRange(location: 0, length: (rawText as NSString).length),
            surface: rawText,
            normalizedLookupKey: rawText,
            tag: .nnp,
            isConvertible: true,
            previewCandidate: candidate
        )
        session.appendCommittedTextToRealtimeClause(rawText)
        session.updateRealtimeAnalysis(segments: [segment], clauseContentFeatures: clauseContentFeatures)

        let engine = InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _, _, _ in
                RealtimeClauseAnalysis(segments: [segment], clauseContentFeatures: clauseContentFeatures)
            },
            analyzeManualClause: { _, _ in [] },
            flushRealtimeUsageEvents: { _ in },
            updateComposition: {},
            debugLog: { _ in }
        )
        return (session, engine, client)
    }

    func testCommitRecordsClauseFeaturesAndAutoConvertedSelectionIntoSessionContext() throws {
        let harness = makeCommitHarness(
            rawText: "한국", previewValue: "韓國", clauseContentFeatures: ["대한/NNP", "국민/NNG"]
        )
        XCTAssertNil(harness.session.sessionScoringInputs, "session buffer starts empty")

        harness.engine.commitCurrentComposition()

        let scoring = try XCTUnwrap(harness.session.sessionScoringInputs)
        XCTAssertEqual(scoring.vocabularyFeatures, ["대한/NNP", "국민/NNG"])
        XCTAssertEqual(scoring.selectionPriors["한국"]?.value, "韓國")
        XCTAssertEqual(scoring.selectionPriors["한국"]?.decay ?? -1, 1.0, accuracy: 1e-9)
    }

    func testDifferentClientsHaveIsolatedSessionContext() {
        let clientA = FakeIMKTextInput()
        let clientB = FakeIMKTextInput()
        let sessionA = InputSessionCache.session(for: clientA)
        let sessionB = InputSessionCache.session(for: clientB)
        XCTAssertFalse(sessionA === sessionB)

        sessionA.recordManualHanjaSelectionToSessionContext(reading: "한국", value: "韓國")

        XCTAssertNotNil(sessionA.sessionScoringInputs, "the recording session must see its own selection")
        XCTAssertNil(sessionB.sessionScoringInputs, "a different client's session must stay untouched")
    }

    func testResetPreservesSessionContextAcrossCommits() throws {
        let session = InputSession()
        session.recordManualHanjaSelectionToSessionContext(reading: "한국", value: "韓國")
        XCTAssertNotNil(session.sessionScoringInputs)

        session.reset()

        let scoring = try XCTUnwrap(session.sessionScoringInputs, "hanjaSessionContext must survive reset()")
        XCTAssertEqual(scoring.selectionPriors["한국"]?.value, "韓國")
        // reset() must still clear ordinary composition state.
        XCTAssertEqual(session.compositionMode, .hangul)
        XCTAssertFalse(session.hasRealtimeClause)
    }
}
