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

    func testXRMultiSyllableWithWeakWordFrequencyPasses() {
        let candidate = candidate(reading: "화려", value: "華麗")
        XCTAssertTrue(
            KiwiAnalysisService.hasAutoConvertWordEvidence(
                candidate,
                tag: .xr,
                wordFrequency: { _ in 72 }
            )
        )
    }

    func testXRMustStillHaveWordTableEvidence() {
        let candidate = candidate(reading: "화려", value: "華麗", comment: "아름답다")
        XCTAssertFalse(
            KiwiAnalysisService.hasAutoConvertWordEvidence(
                candidate,
                tag: .xr,
                wordFrequency: { _ in 0 }
            )
        )
    }

    func testSameWeakCandidateUnderNNGTagStaysBlocked() {
        let candidate = candidate(reading: "화려", value: "華麗")
        XCTAssertFalse(
            KiwiAnalysisService.hasAutoConvertWordEvidence(
                candidate,
                tag: .nng,
                wordFrequency: { _ in 72 }
            )
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

    // MARK: - NNP proper-noun evidence axis (2026-07-11)

    // 국명·지명 실측: decoded freq-hanjaeo 하위값 — 韓國 104, 美國 104, 中國 107, 釜山 84 — all
    // below the step-6 threshold 500, so without the NNP axis every country/place name stays
    // hangul. The tag-aware gate mirrors analyzeClause's production wiring.
    private func nnpAwareGate(wordFrequency: @escaping (String) -> Int) -> (HanjaCandidate, POSTag) -> Bool {
        { candidate, tag in
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, tag: tag, wordFrequency: wordFrequency)
        }
    }

    /// 한국/NNP → 韓國 (하위값 104): the NNP axis accepts weak word-table evidence (> 0) for
    /// multi-syllable proper nouns.
    func testNNPMultiSyllableWithWeakWordFrequencyPreviews() {
        let tokens = [Token(form: "한국", tag: .nnp, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국",
            candidateLookup: { key in key == "한국" ? [self.candidate(reading: key, value: "韓國", comment: "대한민국")] : [] },
            autoConvertGate: nnpAwareGate(wordFrequency: { _ in 104 })
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "韓國")
    }

    /// The same candidate under an NNG tag must stay blocked — only the threshold path applies to
    /// common nouns (this is what keeps 가나다/NNG from converting to the classical transliteration
    /// 加那陀; "가나다순" is a single NNG token per the 2026-07-11 measurement).
    func testSameCandidateUnderNNGTagStaysBlocked() {
        let tokens = [Token(form: "한국", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한국",
            candidateLookup: { key in key == "한국" ? [self.candidate(reading: key, value: "韓國", comment: "대한민국")] : [] },
            autoConvertGate: nnpAwareGate(wordFrequency: { _ in 104 })
        )

        XCTAssertNil(segments.first?.previewCandidate, "104 < 500 and the NNP axis must not apply to NNG")
        XCTAssertTrue(segments.first?.isConvertible == true)
    }

    /// 가락동/NNP → 可樂洞 모사: zero word frequency but a hanja.txt comment (지명 관보) counts as
    /// NNP-axis evidence.
    func testNNPZeroFrequencyWithCommentPreviews() {
        let tokens = [Token(form: "가락동", tag: .nnp, position: 0, length: 3)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "가락동",
            candidateLookup: { key in key == "가락동" ? [self.candidate(reading: key, value: "可樂洞", comment: "지명")] : [] },
            autoConvertGate: nnpAwareGate(wordFrequency: { _ in 0 })
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "可樂洞")
    }

    /// NNP with neither weak word frequency nor a comment has no evidence at all → blocked.
    func testNNPZeroFrequencyWithoutCommentStaysBlocked() {
        let tokens = [Token(form: "회현", tag: .nnp, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "회현",
            candidateLookup: { key in key == "회현" ? [self.candidate(reading: key, value: "會賢")] : [] },
            autoConvertGate: nnpAwareGate(wordFrequency: { _ in 0 })
        )

        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertTrue(segments.first?.isConvertible == true)
    }

    /// Single-syllable NNP stays blocked even with weak frequency and a comment — freq-hanjaeo
    /// has zero 1-syllable rows (step-6 measurement), so 1-syllable "word evidence" is principled-
    /// impossible and single-character 훈음 misconversion risk dominates.
    func testNNPSingleSyllableStaysBlocked() {
        let tokens = [Token(form: "한", tag: .nnp, position: 0, length: 1)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "한",
            candidateLookup: { key in key == "한" ? [self.candidate(reading: key, value: "韓", comment: "나라")] : [] },
            autoConvertGate: nnpAwareGate(wordFrequency: { _ in 104 })
        )

        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertTrue(segments.first?.isConvertible == true)
    }

    // MARK: - Test helpers

    private func candidate(
        reading: String,
        value: String,
        comment: String = "",
        frequency: Int = 0,
        usageCount: Int = 0,
        source: HanjaCandidateSource = .system
    ) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: comment,
            source: source,
            usageCount: usageCount,
            frequency: frequency,
            baseRank: 0
        )
    }
}
