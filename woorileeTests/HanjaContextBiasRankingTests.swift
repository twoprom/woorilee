// Tests for step D3 (런타임 half): consuming the offline export's per-candidate bias prior.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세" §3 (candidate-profile bias slot).
// Three groups: (1) rankWithContext(Scored) + `biases` (ranker unit), (2) contextEvidence must
// never see bias (structural invariant), (3) KiwiAnalysisService.applyContextReranking +
// `associationBiasLookup`, including the awaitsContextEvidence promotion-gate regression that
// pins the design's core safety invariant — bias is a PRIOR, never context evidence (the same
// precedent HanjaContextRanker.sessionContextBoosts set for R1a's session boosts).

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextBiasRankingTests: XCTestCase {
    private func candidate(reading: String, value: String, frequency: Int = 0, comment: String = "") -> HanjaCandidate {
        HanjaCandidate(reading: reading, value: value, comment: comment, source: .system, usageCount: 0, frequency: frequency, baseRank: 0)
    }

    // MARK: - Group 1: rankWithContext(Scored) + biases

    /// Two candidates tied on every other axis (equal frequency, no containment/association
    /// evidence) — WITHOUT bias, `compareHanjaCandidate`'s value-ascending tie-break would put
    /// 佳景 (U+4F73) ahead of 假景 (U+5047). Giving 假景 the larger bias must flip that natural
    /// order — proving bias, not the pre-existing tie-break, decided the winner.
    func testBiasBreaksATieBetweenEquallyMatchedCandidates() {
        let candidates = [
            candidate(reading: "가경", value: "假景", frequency: 100),
            candidate(reading: "가경", value: "佳景", frequency: 100),
        ]

        let unbiased = rankWithContext(candidates: candidates, contextDominantHanja: [], weights: .default)
        XCTAssertEqual(unbiased.first?.value, "佳景", "sanity: without bias, the tie-break naturally favors 佳景")

        let ranked = rankWithContext(
            candidates: candidates,
            contextDominantHanja: [],
            weights: .default,
            biases: ["假景": 50, "佳景": 10]
        )

        XCTAssertEqual(ranked.first?.value, "假景", "larger bias must override the natural tie-break order")
    }

    /// Bias must never overcome containment: offline clamps |bias| <= 100, so the max
    /// contribution is 100 * 300 (weights.association) = 30,000 — far under containment's
    /// 10,000,000 (see HanjaContextRankingWeights.association's doc for the full ceiling math).
    func testBiasNeverOutranksContainment() {
        let candidates = [
            candidate(reading: "수도", value: "首都", frequency: 11750),
            candidate(reading: "수도", value: "水道", frequency: 2106),
        ]

        let ranked = rankWithContext(
            candidates: candidates,
            contextDominantHanja: ["上下水道"], // containment hit for 水道 only
            weights: .default,
            biases: ["首都": 100] // maximal realistic bias, still must lose to containment
        )

        XCTAssertEqual(ranked.first?.value, "水道", "containment (10,000,000) must outrank even the maximal bias contribution (30,000)")
    }

    /// Identity invariant for the new parameter: omitting `biases` (its default `[:]`) must be
    /// indistinguishable from passing an explicit empty dictionary — and, by extension, from every
    /// pre-D3 call site, none of which pass `biases:` at all. Every existing
    /// HanjaContextRankerTests / RealtimeContextRankingTests / ... case already exercises the
    /// omitted-default path and continues to pass unchanged, which is the real fixation of this
    /// invariant; this test just states it explicitly for the new parameter.
    func testOmittedBiasesMatchesExplicitEmptyBiases() {
        let candidates = [
            candidate(reading: "수도", value: "首都", frequency: 11750),
            candidate(reading: "수도", value: "修道", frequency: 2737),
            candidate(reading: "수도", value: "水道", frequency: 2106),
        ]

        let withoutParameter = rankWithContext(candidates: candidates, contextDominantHanja: [], weights: .default)
        let withEmptyBiases = rankWithContext(
            candidates: candidates, contextDominantHanja: [], weights: .default, biases: [:]
        )

        XCTAssertEqual(withoutParameter.map(\.value), withEmptyBiases.map(\.value))
    }

    // MARK: - Group 2: contextEvidence must never see bias (structural invariant)

    /// `contextEvidence`'s parameter list has no `biases` input at all — this test pins that a
    /// candidate with zero matched association features and zero containment reports NO positive
    /// evidence. Bias can only ever reach `rankWithContextScored`'s boost sum, never this
    /// function — the same separation `sessionContextBoosts` established for session boosts (see
    /// that function's doc): a prior must never impersonate context evidence in front of step 7's
    /// `awaitsContextEvidence` promotion gate.
    func testContextEvidenceIgnoresBiasEntirely() {
        let zeroEvidenceCandidate = candidate(reading: "구두", value: "口頭", frequency: 1516)

        let evidence = contextEvidence(
            for: zeroEvidenceCandidate,
            contextDominantHanja: [],
            associationScores: [:], // no matched features
            weights: .default
        )

        XCTAssertFalse(evidence.hasPositiveEvidence, "zero matched features + zero containment must report no evidence")
    }

    // MARK: - Group 3: applyContextReranking + associationBiasLookup

    private func guduCandidates() -> [HanjaCandidate] {
        [
            candidate(reading: "구두", value: "口頭", frequency: 1516),
            candidate(reading: "구두", value: "句讀", frequency: 300),
        ]
    }

    private var passingGate: (HanjaCandidate) -> Bool {
        { candidate in KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 2000 }) }
    }

    /// Tag-aware variant of `passingGate` — needed wherever a test also passes
    /// `associationBiasLookup:`, since that parameter only exists on the tag-aware primary
    /// `applyContextReranking` overload (whose `autoConvertGate` is `(HanjaCandidate, POSTag) ->
    /// Bool`, not the tag-agnostic source-compat overload's `(HanjaCandidate) -> Bool`).
    private var passingGateTagAware: (HanjaCandidate, POSTag) -> Bool {
        { candidate, tag in KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, tag: tag, wordFrequency: { _ in 2000 }) }
    }

    /// Sanity: `associationBiasLookup`, wired all the way through `applyContextReranking`, flips
    /// an ordinary (non-awaits-context-evidence) segment's preview the same way a direct
    /// `rankWithContext(biases:)` call would.
    func testApplyContextRerankingAppliesBiasToOrdinarySegment() throws {
        let sourceText = "우리 집 구두"
        let tokens = [
            Token(form: "우리", tag: .np, position: 0, length: 2),
            Token(form: "집", tag: .nng, position: 3, length: 1),
            Token(form: "구두", tag: .nng, position: 5, length: 2),
        ]
        let lookup: (String) -> [HanjaCandidate] = { key in key == "구두" ? self.guduCandidates() : [] }
        let segments = KiwiAnalysisService.makeRealtimeSegments(from: tokens, in: sourceText, candidateLookup: lookup)

        let before = try XCTUnwrap(segments.first { $0.surface == "구두" })
        XCTAssertEqual(before.previewCandidate?.value, "口頭", "baseline before rerank is the frequency leader")

        // No association features match anything (empty dicts, not nil, so the lookup is "wired"
        // but scores stay 0) — only the bias axis should move the ranking.
        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: lookup,
            winningTokens: tokens,
            associationFeatureLookup: { _, _ in [:] },
            associationBiasLookup: { reading, hanja in
                guard reading == "구두" else { return nil }
                return hanja == "句讀" ? 100 : nil
            }
        )

        let after = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertEqual(after.previewCandidate?.value, "句讀", "a strong bias must be able to flip an ordinary segment's preview")
    }

    /// `associationBiasLookup` defaulting to nil must reproduce pre-D3 behavior exactly, even when
    /// every other input is identical to a case that WOULD flip if the bias lookup were wired.
    func testNilBiasLookupReproducesPreD3Behavior() throws {
        let sourceText = "우리 집 구두"
        let tokens = [
            Token(form: "우리", tag: .np, position: 0, length: 2),
            Token(form: "집", tag: .nng, position: 3, length: 1),
            Token(form: "구두", tag: .nng, position: 5, length: 2),
        ]
        let lookup: (String) -> [HanjaCandidate] = { key in key == "구두" ? self.guduCandidates() : [] }
        let segments = KiwiAnalysisService.makeRealtimeSegments(from: tokens, in: sourceText, candidateLookup: lookup)

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: lookup,
            winningTokens: tokens,
            associationFeatureLookup: { _, _ in [:] }
            // associationBiasLookup defaults to nil.
        )

        let after = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertEqual(after.previewCandidate?.value, "口頭", "nil bias lookup (the default) must leave the frequency leader in place")
    }

    /// THE core invariant regression (most important test in this file): a flagged reading
    /// (`awaitsContextEvidence == true`, mirrors RealtimeNativeHomographGateTests' 구두 fixture)
    /// whose ONLY signal is a large bias on its top-ranked candidate — zero matched association
    /// features, zero containment — must NOT be promoted. If bias ever leaked into
    /// `contextEvidence`, this candidate would look like it has "positive context evidence" and
    /// step 7's native-homograph gate would wrongly auto-convert a bare prior into a committed
    /// Hanja choice.
    func testBiasAloneNeverPromotesAnAwaitsContextEvidenceSegment() throws {
        let sourceText = "구두 오늘"
        let tokens = [
            Token(form: "구두", tag: .nng, position: 0, length: 2),
            Token(form: "오늘", tag: .nng, position: 3, length: 2),
        ]
        let lookup: (String) -> [HanjaCandidate] = { key in
            switch key {
            case "구두": return self.guduCandidates()
            case "오늘": return [self.candidate(reading: "오늘", value: "吾訥", frequency: 10)]
            default: return []
            }
        }
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: lookup,
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" }
        )
        let preSanity = try XCTUnwrap(segments.first { $0.surface == "구두" })
        XCTAssertNil(preSanity.previewCandidate)
        XCTAssertTrue(preSanity.awaitsContextEvidence, "sanity: the fixture must actually reach the awaits-context-evidence state")

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:], // no containment anchor at all
            candidateLookup: lookup,
            winningTokens: tokens,
            // Wired but matches nothing for 구두's candidates — zero association evidence.
            associationFeatureLookup: { reading, _ in reading == "구두" ? [:] : nil },
            // A huge bias on 口頭 alone — big enough to win the rerank outright (100 * 300 =
            // 30,000, more than enough against a candidate with boost 0).
            associationBiasLookup: { reading, hanja in
                guard reading == "구두", hanja == "口頭" else { return nil }
                return 100
            },
            autoConvertGate: passingGateTagAware
        )

        let stillFlagged = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertNil(
            stillFlagged.previewCandidate,
            "bias alone (no matched features, no containment) must never promote an awaitsContextEvidence segment"
        )
    }
}
