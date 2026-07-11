// Tests for step 7: native-homograph gate (어원 기준 자동 변환).
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/context-aware-hanja-conversion.md §10. Mirrors RealtimeAutoConvertGateTests.swift
// — hand-built `Token`s (no real Kiwi), exercising KiwiAnalysisService.makeRealtimeSegments /
// applyContextReranking directly with an injected `nativeHomographLookup`.

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeNativeHomographGateTests: XCTestCase {
    // MARK: - makeRealtimeSegments: suppression for flagged readings

    /// Flagship regression: 구두/NNG has a real native-Korean-word homograph (신발) so the
    /// step-6-passing top candidate (口頭) must NOT preview automatically — the segment instead
    /// waits for positive context evidence.
    func testFlaggedReadingWithNoEvidenceSuppressesPreviewButKeepsConvertible() {
        let tokens = [Token(form: "구두", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "구두",
            candidateLookup: guduLookup(_:),
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertTrue(segments.first?.awaitsContextEvidence == true)
        XCTAssertTrue(segments.first?.isConvertible == true, "candidate panel access must stay available")
    }

    /// 지금: unflagged reading — step 6 gate alone still governs, unchanged by step 7.
    func testUnflaggedReadingKeepsPreStep7Behavior() {
        let tokens = [Token(form: "지금", tag: .mag, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "지금",
            candidateLookup: { key in key == "지금" ? [self.candidate(reading: key, value: "只今")] : [] },
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" } // 지금 is not in the flagged set.
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "只今")
        XCTAssertFalse(segments.first?.awaitsContextEvidence == true)
    }

    /// nil nativeHomographLookup (default) must reproduce pre-step-7 behavior exactly, even for a
    /// reading that WOULD be flagged if the lookup were wired.
    func testNilLookupReproducesPreStep7Behavior() {
        let tokens = [Token(form: "구두", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "구두",
            candidateLookup: guduLookup(_:),
            autoConvertGate: passingGate
            // nativeHomographLookup defaults to nil.
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "口頭")
        XCTAssertFalse(segments.first?.awaitsContextEvidence == true)
    }

    /// Numeric segments never go through the homograph check, even if the lookup is maximally
    /// aggressive (always true).
    func testNumericSegmentsBypassTheHomographCheck() {
        let tokens = [Token(form: "123", tag: .sn, position: 0, length: 3)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "123",
            candidateLookup: NumericHanjaCandidateGenerator.candidates(for:),
            nativeHomographLookup: { _ in true }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments.first?.isConvertible == true)
        XCTAssertNil(segments.first?.previewCandidate)
        XCTAssertFalse(segments.first?.awaitsContextEvidence == true)
    }

    // MARK: - applyContextReranking: promotion on positive evidence

    private func guduCandidates() -> [HanjaCandidate] {
        [
            candidate(reading: "구두", value: "口頭", frequency: 1516),
            candidate(reading: "구두", value: "句讀", frequency: 300),
        ]
    }

    private func guduLookup(_ key: String) -> [HanjaCandidate] {
        key == "구두" ? guduCandidates() : []
    }

    private var passingGate: (HanjaCandidate) -> Bool {
        { candidate in KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 2000 }) }
    }

    /// 구두 + {계약} context → 口頭 promoted via step-5 association evidence (mirrors the plan's
    /// flagship "구두로 계약을 전달했다" scenario).
    func testFlaggedReadingPromotedByAssociationEvidence() throws {
        let sourceText = "구두 계약"
        let tokens = [
            Token(form: "구두", tag: .nng, position: 0, length: 2),
            Token(form: "계약", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: guduLookup(_:),
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" }
        )
        let preSanity = try XCTUnwrap(segments.first { $0.surface == "구두" })
        XCTAssertNil(preSanity.previewCandidate)
        XCTAssertTrue(preSanity.awaitsContextEvidence)

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: guduLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "구두", hanja == "口頭" else { return nil }
                return ["계약/NNG": 69]
            },
            autoConvertGate: passingGate
        )

        let promoted = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertEqual(promoted.previewCandidate?.value, "口頭", "positive association evidence must promote the flagged segment")
    }

    /// 구두시험 (구두 + 시험 forming one eojeol) → 口頭 promoted via step-4 containment/dominance
    /// evidence (mirrors RealtimeAutoConvertGateTests's 상하수도 pattern).
    func testFlaggedReadingPromotedByContainmentEvidence() throws {
        let sourceText = "구두시험 결과"
        let tokens = [
            Token(form: "구두", tag: .nng, position: 0, length: 2),
            Token(form: "시험", tag: .nng, position: 2, length: 2),
            Token(form: "결과", tag: .nng, position: 5, length: 2),
        ]
        let lookup: (String) -> [HanjaCandidate] = { key in
            switch key {
            case "구두": return self.guduCandidates()
            case "시험": return [self.candidate(reading: "시험", value: "試驗", frequency: 5000)]
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

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: ["구두시험": "口頭試驗"],
            candidateLookup: lookup,
            autoConvertGate: passingGate
        )

        let promoted = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertEqual(promoted.previewCandidate?.value, "口頭", "containment evidence must promote the flagged segment")
    }

    /// No context evidence at all (reranking runs, but neither axis fires) → stays hangul.
    func testFlaggedReadingStaysHangulWithoutEvidence() throws {
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

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: ["오늘": "吾訥"], // unrelated dominant hanja; no containment/association hit on 口頭.
            candidateLookup: lookup,
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "구두", hanja == "口頭" else { return nil }
                return ["결혼/NNG": 50] // present in the table but not in this clause's features.
            },
            autoConvertGate: passingGate
        )

        let stillHangul = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertNil(stillHangul.previewCandidate, "no positive evidence must leave the flagged segment hangul")
    }

    /// Reranking never actually runs (no dominant-hanja context and no association lookup at
    /// all — mirrors `useContextHanjaRanking` being off / stores not ready in `analyzeClause`):
    /// the flagged segment must stay hangul, not silently fall back to the pre-step-7 preview.
    func testFlaggedReadingStaysHangulWhenRerankingDoesNotRun() throws {
        let tokens = [Token(form: "구두", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "구두",
            candidateLookup: guduLookup(_:),
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" }
        )

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: "구두",
            dominantMap: [:],
            candidateLookup: guduLookup(_:)
            // associationFeatureLookup defaults to nil, winningTokens defaults to [] — no context
            // signal reaches the ranker at all, so applyContextReranking's own early-return fires.
        )

        let unchanged = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertNil(unchanged.previewCandidate)
        XCTAssertTrue(unchanged.awaitsContextEvidence)
    }

    /// A promoted candidate that fails the step-6 word-evidence gate must not be promoted.
    func testPromotionCandidateStillSubjectToStep6Gate() throws {
        let sourceText = "구두 계약"
        let tokens = [
            Token(form: "구두", tag: .nng, position: 0, length: 2),
            Token(form: "계약", tag: .nng, position: 3, length: 2),
        ]
        // Gate that has word evidence for nothing — mirrors RealtimeAutoConvertGateTests's
        // zero-frequency gate. The segment is still built with a PASSING gate so it reaches the
        // awaitsContextEvidence state (matching production: only step-6-eligible readings can be
        // flagged in the first place — see build_native_homograph_inventory.py's 7a corpus). The
        // promotion attempt uses the strict (failing) gate to prove step 6 still applies at
        // promotion time.
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: guduLookup(_:),
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "구두" }
        )

        let failingGate: (HanjaCandidate) -> Bool = { candidate in
            KiwiAnalysisService.hasAutoConvertWordEvidence(candidate, wordFrequency: { _ in 0 })
        }

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: guduLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "구두", hanja == "口頭" else { return nil }
                return ["계약/NNG": 69]
            },
            autoConvertGate: failingGate
        )

        let stillHangul = try XCTUnwrap(reranked.first { $0.surface == "구두" })
        XCTAssertNil(stillHangul.previewCandidate, "positive context evidence must not bypass the step-6 gate")
    }

    // MARK: - Promotion-candidate selection (gate-failing rerank winners are skipped)

    // 고장 scenario: 姑藏 (rare, step-6 gate fails, but its dictionary features can win the
    // rerank) vs 故障 (gate passes, carries the real association evidence).
    private func gojangCandidates() -> [HanjaCandidate] {
        [
            candidate(reading: "고장", value: "故障", frequency: 7492),
            candidate(reading: "고장", value: "姑藏", frequency: 10),
        ]
    }

    private func gojangLookup(_ key: String) -> [HanjaCandidate] {
        key == "고장" ? gojangCandidates() : []
    }

    /// Gate that only 故障 passes (word evidence 7492 >= 500; 姑藏 has none).
    private var gojangGate: (HanjaCandidate) -> Bool {
        { candidate in
            KiwiAnalysisService.hasAutoConvertWordEvidence(
                candidate,
                wordFrequency: { $0 == "故障" ? 7492 : 0 }
            )
        }
    }

    /// Rerank winner fails the step-6 gate (姑藏 boosted above 故障 by a spurious feature match),
    /// but the first GATE-PASSING candidate (故障) has its own positive evidence → 故障 promoted.
    func testPromotionSkipsGateFailingRerankWinner() throws {
        let sourceText = "수도 고장"
        let tokens = [
            Token(form: "수도", tag: .nng, position: 0, length: 2),
            Token(form: "고장", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: gojangLookup(_:),
            autoConvertGate: gojangGate,
            nativeHomographLookup: { $0 == "고장" }
        )
        let preSanity = try XCTUnwrap(segments.first { $0.surface == "고장" })
        XCTAssertNil(preSanity.previewCandidate)
        XCTAssertTrue(preSanity.awaitsContextEvidence)

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: gojangLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                guard reading == "고장" else { return nil }
                switch hanja {
                // 姑藏's dictionary definition mentions 수도 — a big spurious weight that wins
                // the rerank (10 + 255*300 ≫ 7492 + 40*300).
                case "姑藏": return ["수도/NNG": 255]
                // 故障's legitimate association evidence.
                case "故障": return ["수도/NNG": 40]
                default: return nil
                }
            },
            autoConvertGate: gojangGate
        )

        let promoted = try XCTUnwrap(reranked.first { $0.surface == "고장" })
        XCTAssertEqual(
            promoted.previewCandidate?.value, "故障",
            "the gate-failing rerank winner (姑藏) must be skipped, not block 故障's promotion"
        )
    }

    /// The first gate-passing candidate has NO evidence of its own — the skipped (gate-failing)
    /// winner's evidence must not transfer to it. Stays hangul.
    func testPromotionRequiresEvidenceOnTheGatePassingCandidateItself() throws {
        let sourceText = "수도 고장"
        let tokens = [
            Token(form: "수도", tag: .nng, position: 0, length: 2),
            Token(form: "고장", tag: .nng, position: 3, length: 2),
        ]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: sourceText,
            candidateLookup: gojangLookup(_:),
            autoConvertGate: gojangGate,
            nativeHomographLookup: { $0 == "고장" }
        )

        let reranked = KiwiAnalysisService.applyContextReranking(
            to: segments,
            clause: sourceText,
            dominantMap: [:],
            candidateLookup: gojangLookup(_:),
            winningTokens: tokens,
            associationFeatureLookup: { reading, hanja in
                // Only the gate-FAILING candidate has any matching feature; 故障 has none.
                guard reading == "고장", hanja == "姑藏" else { return nil }
                return ["수도/NNG": 255]
            },
            autoConvertGate: gojangGate
        )

        let stillHangul = try XCTUnwrap(reranked.first { $0.surface == "고장" })
        XCTAssertNil(
            stillHangul.previewCandidate,
            "a skipped candidate's evidence must not promote an evidence-less gate-passing candidate"
        )
    }

    // MARK: - Personalization bypass (usageCount / userDefined skip the suppression)

    /// Flagged reading whose top candidate the user has picked before (usageCount > 0) → the
    /// suppression is skipped entirely and the pre-step-7 preview stands.
    func testFlaggedReadingWithUsageCountBypassesSuppression() {
        let tokens = [Token(form: "고장", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "고장",
            candidateLookup: { key in
                key == "고장" ? [self.candidate(reading: key, value: "故障", frequency: 7492, usageCount: 1)] : []
            },
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "고장" }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "故障", "usageCount > 0 is the strongest evidence — no suppression")
        XCTAssertFalse(segments.first?.awaitsContextEvidence == true)
    }

    /// Same bypass for a user-defined top candidate.
    func testFlaggedReadingWithUserDefinedCandidateBypassesSuppression() {
        let tokens = [Token(form: "고장", tag: .nng, position: 0, length: 2)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: "고장",
            candidateLookup: { key in
                key == "고장" ? [self.candidate(reading: key, value: "故障", frequency: 7492, source: .userDefined)] : []
            },
            autoConvertGate: passingGate,
            nativeHomographLookup: { $0 == "고장" }
        )

        XCTAssertEqual(segments.first?.previewCandidate?.value, "故障", "user-defined entries bypass the suppression")
        XCTAssertFalse(segments.first?.awaitsContextEvidence == true)
    }

    // MARK: - Bundled resource parsing

    /// Loads the real bundled `hanja-native-homograph.txt` from its repo path (mirrors
    /// HanjaContextEvalTests's repo-path loading pattern) and checks the flagship inclusion:
    /// 구두 (real native-word homograph) flagged, 지금 (no native-word homograph) not flagged.
    func testBundledNativeHomographResourceContainsFlagshipReadings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("woorilee/data/hanja/hanja-native-homograph.txt")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let readings = HanjaDictionaryService.parseNativeHomographReadings(contents: contents)

        XCTAssertTrue(readings.contains("구두"))
        XCTAssertFalse(readings.contains("지금"))
        XCTAssertGreaterThanOrEqual(readings.count, 400, "flagged set should be close to the 482-reading 7a/7b final list")
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
