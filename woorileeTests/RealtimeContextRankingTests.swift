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
