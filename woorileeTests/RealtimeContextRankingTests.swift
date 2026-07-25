// Tests for step 4b: wiring context ranking into the realtime analysis path.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/context-aware-hanja-conversion.md §5. Uses hand-built `Token`s (no real Kiwi),
// mirroring RealtimeHanjaAnalysisTests.swift, to exercise
// KiwiAnalysisService.applyContextReranking / .clauseContextDominantHanja directly.

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeContextRankingTests: XCTestCase {
    // Decoded freq-hanjaeo.txt order for reading 수도 (§0 실측): 首都 > 修道 > 水道.
    private func sudoCandidates() -> [HanjaCandidate] {
        [
            candidate(reading: "수도", value: "首都", frequency: 11750),
            candidate(reading: "수도", value: "修道", frequency: 2737),
            candidate(reading: "수도", value: "水道", frequency: 2106),
        ]
    }

    private func sudoLookup(_ key: String) -> [HanjaCandidate] {
        key == "수도" ? sudoCandidates() : []
    }

    // MARK: - clauseContextDominantHanja eojeol grouping

    func testClauseContextDominantHanjaGroupsAdjacentSegmentsIntoOneEojeol() {
        let sourceText = "상하수도 막힘"
        // "상하" + "수도" have no space between their sourceRanges → same eojeol → "상하수도".
        let segments = [
            hangulSegment(surface: "상하", location: 0, length: 2),
            hangulSegment(surface: "수도", location: 2, length: 2),
            hangulSegment(surface: "막힘", location: 5, length: 2),
        ]
        let dominantMap = ["상하수도": "上下水道"]

        let context = KiwiAnalysisService.clauseContextDominantHanja(
            clause: sourceText,
            segments: segments,
            dominantMap: dominantMap
        )

        XCTAssertEqual(context, ["上下水道"])
    }

    func testClauseContextDominantHanjaTreatsSpaceSeparatedSegmentsAsSeparateEojeols() {
        let sourceText = "수도 막힘"
        // A space between "수도" and "막힘" → separate eojeols → reading "수도" alone (not "수도막힘").
        let segments = [
            hangulSegment(surface: "수도", location: 0, length: 2),
            hangulSegment(surface: "막힘", location: 3, length: 2),
        ]
        // Only the standalone "수도" reading is dominant; "수도막힘" (never formed) is absent.
        let dominantMap = ["수도": "水道要覽", "수도막힘": "should-not-be-used"]

        let context = KiwiAnalysisService.clauseContextDominantHanja(
            clause: sourceText,
            segments: segments,
            dominantMap: dominantMap
        )

        XCTAssertEqual(context, ["水道要覽"])
    }

    // MARK: - applyContextReranking

    func testApplyContextRerankingSetsWaterPipePreviewForSangHaSudoClause() throws {
        let sourceText = "상하수도 막힘"
        let tokens = [
            Token(form: "상하", tag: .nng, position: 0, length: 2),
            Token(form: "수도", tag: .nng, position: 2, length: 2),
            Token(form: "막힘", tag: .nng, position: 5, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: sudoLookup(_:)
        )
        // Baseline (pre-rerank): the 수도 segment's preview defaults to the frequency leader, 首都.
        let waterPipeIndexBefore = try XCTUnwrap(segments.firstIndex { $0.surface == "수도" })
        XCTAssertEqual(segments[waterPipeIndexBefore].previewCandidate?.value, "首都")

        let dominantMap = ["상하수도": "上下水道"]
        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: dominantMap,
            candidateLookup: sudoLookup(_:)
        )

        let waterPipeSegment = try XCTUnwrap(reranked.first { $0.surface == "수도" })
        XCTAssertEqual(waterPipeSegment.previewCandidate?.value, "水道")
        XCTAssertEqual(waterPipeSegment.contextDominantHanja, ["上下水道"])

        // Every segment (not just the reranked one) is stamped with the resolved context.
        XCTAssertTrue(reranked.allSatisfy { $0.contextDominantHanja == ["上下水道"] })

        // R2 (docs/plans/hanja-context-scaling-plan.md §7) identity check: this clause has only
        // ONE target segment ("수도" — "상하"/"막힘" have no candidates via `sudoLookup`), so the
        // joint stage's ">= 2 participating segments" gate never opens — every segment's
        // `jointBoosts` must stay empty, reproducing R1 exactly.
        XCTAssertTrue(reranked.allSatisfy { $0.jointBoosts.isEmpty }, "single-target clause must never populate jointBoosts")
    }

    func testApplyContextRerankingLeavesNonPreviewSegmentsNilAndUnaffected() throws {
        // "그것" tags as .np, which isRealtimeAutoConvertEligibleTag excludes — its preview must
        // stay nil after reranking (eligibility rules are not duplicated/bypassed by this step).
        let sourceText = "그것 수도"
        let tokens = [
            Token(form: "그것", tag: .np, position: 0, length: 2),
            Token(form: "수도", tag: .nng, position: 3, length: 2),
        ]
        let lookup: (String) -> [HanjaCandidate] = { key in
            switch key {
            case "그것": return [self.candidate(reading: key, value: "其", frequency: 1)]
            case "수도": return self.sudoCandidates()
            default: return []
            }
        }
        let segments = KiwiAnalysisService.makeRealtimeSegments(from: tokens, in: sourceText, candidateLookup: lookup)
        let excludedSegmentBefore = try XCTUnwrap(segments.first { $0.surface == "그것" })
        XCTAssertNil(excludedSegmentBefore.previewCandidate)

        let dominantMap = ["그것": "其", "수도": "水道"]
        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: dominantMap,
            candidateLookup: lookup
        )

        let excludedSegmentAfter = try XCTUnwrap(reranked.first { $0.surface == "그것" })
        XCTAssertNil(excludedSegmentAfter.previewCandidate, "non-auto-convert-eligible segment must stay nil")
        // It still gets stamped with the resolved context (for panel use), just no preview override.
        XCTAssertEqual(excludedSegmentAfter.contextDominantHanja, ["其", "水道"])
    }

    // MARK: - Fallback invariant

    func testApplyContextRerankingWithEmptyDominantMapLeavesSegmentsUnchanged() {
        let sourceText = "상하수도 막힘"
        let tokens = [
            Token(form: "상하", tag: .nng, position: 0, length: 2),
            Token(form: "수도", tag: .nng, position: 2, length: 2),
            Token(form: "막힘", tag: .nng, position: 5, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: sudoLookup(_:)
        )

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: sudoLookup(_:)
        )

        XCTAssertEqual(reranked, segments, "empty dominantMap must be a full no-op")
    }

    func testApplyContextRerankingWithNoApplicableContextLeavesPreviewsAndOrderUnchanged() {
        // dominantMap is non-empty, but nothing in this clause resolves against it.
        let sourceText = "상하수도 막힘"
        let tokens = [
            Token(form: "상하", tag: .nng, position: 0, length: 2),
            Token(form: "수도", tag: .nng, position: 2, length: 2),
            Token(form: "막힘", tag: .nng, position: 5, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: sudoLookup(_:)
        )

        let unrelatedDominantMap = ["전혀다른읽기": "全然다른한자"]
        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: unrelatedDominantMap,
            candidateLookup: sudoLookup(_:)
        )

        XCTAssertEqual(reranked, segments, "context that resolves to nothing must be a full no-op")
    }

    // MARK: - Step 5c: association scoring (docs/plans/context-aware-hanja-conversion.md §7 5c)

    /// Flagship: "우리 집 수도" has no hanja anchor (집 has no hanja mapping), so step 4b's
    /// containment axis is blind here (dominantMap empty ⇒ context == []). A stubbed association
    /// lookup surfacing the real 水道:집/NNG=37 weight (see HanjaContextAssociationStoreTests) must
    /// still flip the preview from the frequency leader (首都) to 水道.
    func testApplyContextRerankingUsesAssociationScoreWhenNoContainmentAnchorExists() throws {
        let sourceText = "우리 집 수도"
        let tokens = [
            Token(form: "우리", tag: .np, position: 0, length: 2),
            Token(form: "집", tag: .nng, position: 3, length: 1),
            Token(form: "수도", tag: .nng, position: 5, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(from: tokens, in: sourceText, candidateLookup: sudoLookup(_:))

        let waterPipeIndexBefore = try XCTUnwrap(segments.firstIndex { $0.surface == "수도" })
        XCTAssertEqual(segments[waterPipeIndexBefore].previewCandidate?.value, "首都", "baseline before rerank is the frequency leader")

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: sudoLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "수도", hanja == "水道" else { return nil }
                return ["집/NNG": 37]
            }
        )

        let waterPipeSegment = try XCTUnwrap(reranked.first { $0.surface == "수도" })
        XCTAssertEqual(waterPipeSegment.previewCandidate?.value, "水道")
        XCTAssertEqual(waterPipeSegment.contextFeatures, ["집/NNG"], "우리/NP is not a content-morpheme tag; 수도/NNG is self-excluded")
    }

    /// Self-exclusion: the 수도 segment's own token (수도/NNG) must never vote for its own
    /// candidates, even if a stubbed lookup would score it. Without self-exclusion this would
    /// wrongly flip the same clause's preview to 水道; with it, nothing in the (empty) remaining
    /// context matches, so the frequency default (首都) is preserved.
    func testApplyContextRerankingExcludesSegmentsOwnTokenFromItsOwnAssociationScore() throws {
        let sourceText = "우리 집 수도"
        let tokens = [
            Token(form: "우리", tag: .np, position: 0, length: 2),
            Token(form: "집", tag: .nng, position: 3, length: 1),
            Token(form: "수도", tag: .nng, position: 5, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(from: tokens, in: sourceText, candidateLookup: sudoLookup(_:))

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: sudoLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "수도", hanja == "水道" else { return nil }
                // Only the segment's own surface/tag would score here; self-exclusion must drop it.
                return ["수도/NNG": 255]
            }
        )

        let waterPipeSegment = try XCTUnwrap(reranked.first { $0.surface == "수도" })
        XCTAssertEqual(waterPipeSegment.previewCandidate?.value, "首都", "the segment's own token must not vote for its own candidates")
        // contextFeatures is the segment-specific token list (self-excluded), independent of what
        // the association lookup happens to score — 집/NNG survives self-exclusion (a different
        // token), 수도/NNG does not (it's the segment's own token).
        XCTAssertEqual(waterPipeSegment.contextFeatures, ["집/NNG"])
    }

    // MARK: - Step R2 (docs/plans/hanja-context-scaling-plan.md §7): joint selection wiring

    /// The R2 joint axis is parked OFF by default (`HanjaContextRankingWeights.default.
    /// jointDomainConsistency == 0`, 2026-07-25 user decision — see the doc comment on that
    /// property). Tests below need PASS 2 to actually run, so they build weights explicitly with
    /// `jointDomainConsistency: 20` (the value R2's own measurement used) instead of relying on
    /// `.default`.
    private func jointOnWeights() -> HanjaContextRankingWeights {
        var weights = HanjaContextRankingWeights.default
        weights.jointDomainConsistency = 20
        return weights
    }

    /// Self-exclusion interaction (spec §3.4 test #3): with the R2 joint stage active (two
    /// participating segments, a strong cross-profile match), each segment's `contextFeatures`
    /// must still exclude its OWN surface and include only the OTHER segment's — PASS 2 "does not
    /// touch `segmentFeatures` computation" (spec §3.2's self-exclusion-rule invariant).
    func testJointSelectionDoesNotDisturbSelfExclusion() throws {
        let sourceText = "가정 나선"
        let tokens = [
            Token(form: "가정", tag: .nng, position: 0, length: 2),
            Token(form: "나선", tag: .nng, position: 3, length: 2),
        ]
        let segmentA = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2), surface: "가정", normalizedLookupKey: "가정",
            tag: .nng, isConvertible: true, previewCandidate: candidate(reading: "가정", value: "甲", frequency: 100)
        )
        let segmentB = HanjaSegment(
            sourceRange: NSRange(location: 3, length: 2), surface: "나선", normalizedLookupKey: "나선",
            tag: .nng, isConvertible: true, previewCandidate: candidate(reading: "나선", value: "丙", frequency: 100)
        )

        let lookup: (String) -> [HanjaCandidate] = { key in
            switch key {
            case "가정": return [self.candidate(reading: "가정", value: "甲", frequency: 100), self.candidate(reading: "가정", value: "乙", frequency: 50)]
            case "나선": return [self.candidate(reading: "나선", value: "丙", frequency: 100), self.candidate(reading: "나선", value: "丁", frequency: 50)]
            default: return []
            }
        }
        // A strong cross profile match (甲 x 丙) so PASS 2 actually has something to do — the
        // point of this test is that even so, self-exclusion is untouched.
        let sharedProfile = ["s1/NNG": 10.0, "s2/NNG": 10.0, "s3/NNG": 10.0, "s4/NNG": 10.0, "s5/NNG": 10.0]
        let assocLookup: (String, String) -> [String: Double]? = { reading, hanja in
            switch (reading, hanja) {
            case ("가정", "甲"), ("나선", "丙"): return sharedProfile
            default: return [:]
            }
        }

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: [segmentA, segmentB], clause: sourceText, dominantMap: [:], candidateLookup: lookup,
            winningTokens: tokens, associationFeatureLookup: assocLookup, weights: jointOnWeights()
        )

        let rerankedA = try XCTUnwrap(reranked.first { $0.surface == "가정" })
        let rerankedB = try XCTUnwrap(reranked.first { $0.surface == "나선" })
        XCTAssertEqual(rerankedA.contextFeatures, ["나선/NNG"], "가정's own token must not vote for its own candidates")
        XCTAssertEqual(rerankedB.contextFeatures, ["가정/NNG"], "나선's own token must not vote for its own candidates")
    }

    /// Promotion-gate interaction (spec §3.4 test #4): an `awaitsContextEvidence` segment whose
    /// joint bonus promotes a DIFFERENT top-ranked candidate must still stay hangul if that
    /// candidate has no context evidence OF ITS OWN — the joint bonus never enters
    /// `contextEvidence`/the promotion gate (R2 승격 게이트 불변, spec §3.2). Fixture: segment A's
    /// candidate 乙 (rank 2 by frequency, NOT the frequency leader 甲) shares an identical
    /// association profile with segment B's already-winning candidate 丙 — cos(乙, 丙) = 1.0, a
    /// huge joint bonus that flips PASS 2's chosen index for A to 乙. But 乙 has ZERO context
    /// evidence of its own (`associationScores`/`contextDominantHanja` never point at it, only the
    /// joint axis does) — so the promotion check must reject it and A stays hangul.
    func testJointSelectionNeverPromotesAwaitsContextEvidenceThroughJointBonusAlone() throws {
        let sourceText = "가정 나선"
        let tokens = [
            Token(form: "가정", tag: .nng, position: 0, length: 2),
            Token(form: "나선", tag: .nng, position: 3, length: 2),
        ]
        let segmentA = HanjaSegment(
            sourceRange: NSRange(location: 0, length: 2), surface: "가정", normalizedLookupKey: "가정",
            tag: .nng, isConvertible: true, previewCandidate: nil, awaitsContextEvidence: true
        )
        let segmentB = HanjaSegment(
            sourceRange: NSRange(location: 3, length: 2), surface: "나선", normalizedLookupKey: "나선",
            tag: .nng, isConvertible: true, previewCandidate: candidate(reading: "나선", value: "丙", frequency: 100)
        )

        let lookup: (String) -> [HanjaCandidate] = { key in
            switch key {
            case "가정": return [self.candidate(reading: "가정", value: "甲", frequency: 100), self.candidate(reading: "가정", value: "乙", frequency: 50)]
            case "나선": return [self.candidate(reading: "나선", value: "丙", frequency: 100), self.candidate(reading: "나선", value: "丁", frequency: 50)]
            default: return []
            }
        }
        let sharedProfile = ["s1/NNG": 10.0, "s2/NNG": 10.0, "s3/NNG": 10.0, "s4/NNG": 10.0, "s5/NNG": 10.0]
        // 甲 (the frequency leader, index 0) has an UNRELATED profile — no joint match with 丙.
        // 乙 (index 1) shares 丙's exact profile — the joint stage will prefer (乙, 丙).
        let disjointProfile = ["m1/NNG": 1.0, "m2/NNG": 1.0, "m3/NNG": 1.0, "m4/NNG": 1.0, "m5/NNG": 1.0]
        let assocLookup: (String, String) -> [String: Double]? = { reading, hanja in
            switch (reading, hanja) {
            case ("가정", "甲"): return disjointProfile
            case ("가정", "乙"), ("나선", "丙"): return sharedProfile
            default: return [:]
            }
        }

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: [segmentA, segmentB], clause: sourceText, dominantMap: [:], candidateLookup: lookup,
            winningTokens: tokens, associationFeatureLookup: assocLookup, weights: jointOnWeights()
        )

        let rerankedA = try XCTUnwrap(reranked.first { $0.surface == "가정" })
        XCTAssertGreaterThan(rerankedA.jointBoosts["乙"] ?? 0, 0, "sanity: 乙 must have received a joint bonus (the joint stage must have promoted it into the reranked order)")
        XCTAssertNil(rerankedA.previewCandidate, "乙 has no context evidence of its own — the joint bonus alone must not promote it")
    }

    /// Combination-count cap (spec §3.4 test #5): more than `HanjaJointSelectionLimits.maxSegments`
    /// participating segments must skip PASS 2 entirely — every segment's `jointBoosts` stays
    /// empty and the reranked order is untouched, even though a fixture pair (가/나) has a
    /// deliberately huge joint bonus available (proving the skip, not a coincidental zero score).
    /// Uses `jointOnWeights()` explicitly (not `.default`, now parked at `jointDomainConsistency =
    /// 0`) so the skip this test pins is actually caused by the `maxSegments` cap, not by the
    /// parked-off weight's own shallow guard (which would skip PASS 2 for an unrelated reason and
    /// make this test pass without exercising the cap at all).
    func testJointSelectionSkipsAboveMaxSegments() throws {
        let readings = ["가", "나", "다", "라", "마", "바"]
        XCTAssertGreaterThan(readings.count, HanjaJointSelectionLimits.maxSegments)

        var tokens: [Token] = []
        var segments: [HanjaSegment] = []
        var location = 0
        for reading in readings {
            tokens.append(Token(form: reading, tag: .nng, position: location, length: 1))
            segments.append(HanjaSegment(
                sourceRange: NSRange(location: location, length: 1), surface: reading, normalizedLookupKey: reading,
                tag: .nng, isConvertible: true, previewCandidate: candidate(reading: reading, value: "\(reading)1", frequency: 100)
            ))
            location += 2 // single space between tokens
        }
        let sourceText = readings.joined(separator: " ")

        let lookup: (String) -> [HanjaCandidate] = { key in
            guard readings.contains(key) else { return [] }
            return [self.candidate(reading: key, value: "\(key)1", frequency: 100), self.candidate(reading: key, value: "\(key)2", frequency: 50)]
        }
        // A juicy cross-profile match between 가's and 나's SECOND candidate (index 1, not the
        // default winner) — if PASS 2 ran, this would flip both. It must never run at all.
        let sharedProfile = ["s1/NNG": 10.0, "s2/NNG": 10.0, "s3/NNG": 10.0, "s4/NNG": 10.0, "s5/NNG": 10.0]
        let assocLookup: (String, String) -> [String: Double]? = { reading, hanja in
            switch (reading, hanja) {
            case ("가", "가2"), ("나", "나2"): return sharedProfile
            default: return [:]
            }
        }

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments, clause: sourceText, dominantMap: [:], candidateLookup: lookup,
            winningTokens: tokens, associationFeatureLookup: assocLookup, weights: jointOnWeights()
        )

        XCTAssertTrue(reranked.allSatisfy { $0.jointBoosts.isEmpty }, "above maxSegments, jointBoosts must stay empty for every segment")
        // Reranked order/preview must be untouched — PASS 3 alone (frequency leader stays first).
        for (original, updated) in zip(segments, reranked) {
            XCTAssertEqual(updated.previewCandidate?.value, original.previewCandidate?.value)
        }
    }

    // MARK: - Test helpers

    private func hangulSegment(surface: String, location: Int, length: Int) -> HanjaSegment {
        HanjaSegment(
            sourceRange: NSRange(location: location, length: length),
            surface: surface,
            normalizedLookupKey: surface,
            tag: .nng,
            isConvertible: false,
            previewCandidate: nil
        )
    }

    private func candidate(reading: String, value: String, frequency: Int = 0, usageCount: Int = 0) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: "",
            source: .system,
            usageCount: usageCount,
            frequency: frequency,
            baseRank: 0
        )
    }
}
