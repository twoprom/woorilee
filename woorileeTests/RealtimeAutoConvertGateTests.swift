// Tests for step 6: auto-convert word evidence gate.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/context-aware-hanja-conversion.md §9. Uses hand-built `Token`s (no real Kiwi),
// mirroring RealtimeHanjaAnalysisTests.swift / RealtimeContextRankingTests.swift, to exercise
// KiwiAnalysisService.hasAutoConvertWordEvidence / makeRealtimeSegments / applyContextReranking
// directly with an injected `autoConvertGate`.

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeAutoConvertGateTests: XCTestCase {
    // MARK: - hasAutoConvertWordEvidence

    func testHasAutoConvertWordEvidenceFailsBelowThreshold() {
        let candidate = candidate(reading: "집", value: "集")
        XCTAssertFalse(
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 499 })
        )
    }

    func testHasAutoConvertWordEvidencePassesAtThreshold() {
        let candidate = candidate(reading: "수도", value: "水道")
        XCTAssertTrue(
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 500 })
        )
    }

    func testHasAutoConvertWordEvidencePassesWithUsageCountEvenAtZeroFrequency() {
        let candidate = candidate(reading: "집", value: "集", usageCount: 1)
        XCTAssertTrue(
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
        )
    }

    func testHasAutoConvertWordEvidencePassesForUserDefinedEvenAtZeroFrequency() {
        let candidate = candidate(reading: "집", value: "集", source: .userDefined)
        XCTAssertTrue(
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
        )
    }

    // MARK: - makeRealtimeSegments: gate applied to the token path

    /// Flagship regression: 집/NNG only has a single-character 訓音 candidate (集) with no word
    /// evidence — the gate must suppress the preview while leaving `isConvertible` (candidate
    /// panel access) untouched.
    func testGateSuppressesPreviewForWordEvidencelessCandidate() {
        let tokens = [Token(form: "집", tag: .nng, position: 0, length: 1)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "집",
            candidateLookup: { key in key == "집" ? [self.candidate(reading: key, value: "集")] : [] },
            autoConvertGate: { candidate in
                KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 92 })
            }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertTrue(segments.first?.isConvertible == true, "candidate panel access must stay available")
    }

    func testGateKeepsPreviewWhenTopCandidateMeetsWordFrequencyThreshold() {
        let tokens = [Token(form: "수도", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "수도",
            candidateLookup: { key in key == "수도" ? [self.candidate(reading: key, value: "水道")] : [] },
            autoConvertGate: { candidate in
                KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 2106 })
            }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "水道")
    }

    func testGateKeepsPreviewWhenTopCandidateHasUsageOverride() {
        let tokens = [Token(form: "집", tag: .nng, position: 0, length: 1)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "집",
            candidateLookup: { key in
                key == "집" ? [self.candidate(reading: key, value: "集", usageCount: 1)] : []
            },
            autoConvertGate: { candidate in
                KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
            }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "集", "usageCount > 0 overrides missing word evidence")
    }

    func testGateKeepsPreviewWhenTopCandidateIsUserDefined() {
        let tokens = [Token(form: "집", tag: .nng, position: 0, length: 1)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "집",
            candidateLookup: { key in
                key == "집" ? [self.candidate(reading: key, value: "集", source: .userDefined)] : []
            },
            autoConvertGate: { candidate in
                KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
            }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "集", "user-defined entries override missing word evidence")
    }

    func testNilGateReproducesPreStep6Behavior() {
        let tokens = [Token(form: "집", tag: .nng, position: 0, length: 1)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "집",
            candidateLookup: { key in key == "집" ? [self.candidate(reading: key, value: "集")] : [] }
            // autoConvertGate defaults to nil.
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "集", "no gate injected == pre-step-6 behavior")
    }

    func testNumericSegmentsBypassTheGateEvenWhenItRejectsEverything() {
        let tokens = [Token(form: "123", tag: .sn, position: 0, length: 3)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "123",
            candidateLookup: NumericHanjaCandidateGenerator.candidates(for:),
            autoConvertGate: { _ in false }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments.first?.isConvertible == true)
        // Numeric segments never preview auto-convert regardless of the gate (unchanged UX).
        XCTAssertNil(segments.first?.previewCandidate)
    }

    // MARK: - applyContextReranking: gate applied to reranked.first

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

    func testApplyContextRerankingSuppressesPreviewWhenRerankedTopFailsGate() throws {
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

        let dominantMap = ["상하수도": "上下水道"]
        // Sanity: without a gate, reranking flips the preview to 水道 (mirrors
        // RealtimeContextRankingTests's flagship case).
        let rerankedWithoutGate = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: dominantMap,
            candidateLookup: sudoLookup(_:)
        )
        let waterPipeBefore = try XCTUnwrap(rerankedWithoutGate.first { $0.surface == "수도" })
        XCTAssertEqual(waterPipeBefore.previewCandidate?.value, "水道")

        // With a gate that has no word evidence for 水道, the reranked top candidate must not
        // become the preview — the segment stays hangul rather than silently promoting the next
        // candidate.
        let rerankedWithGate = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: dominantMap,
            candidateLookup: sudoLookup(_:),
            autoConvertGate: { candidate in
                KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
            }
        )
        let waterPipeAfter = try XCTUnwrap(rerankedWithGate.first { $0.surface == "수도" })
        XCTAssertNil(waterPipeAfter.previewCandidate, "reranked.first failing the gate must not be promoted")
    }

    // MARK: - Test helpers

    private func candidate(
        reading: String,
        value: String,
        frequency: Int = 0,
        usageCount: Int = 0,
        source: HanjaCandidateSource = .system
    ) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: "",
            source: source,
            usageCount: usageCount,
            frequency: frequency,
            baseRank: 0
        )
    }
}
