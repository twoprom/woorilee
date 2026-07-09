// Regression tests for the functional-span containment guard in
// KiwiAnalysisService.bestRealtimeSegmentsWithWinningTokens: a josa (조사) must never be converted
// to hanja just because a lower-scored Kiwi tokenization mis-tags it as a hanja-eligible POS.
//
// Bug: "수도 배관이 고장났다" converted to "水道 配管二 故障났다" — the josa 이 (after 배관) was
// converted to the numeral hanja 二. Diagnosis (real Kiwi, topN=3) confirmed the mechanism: the
// top-SCORE analysis correctly tags 이 as JKS (josa, not hanja-eligible), but a lower-scored
// alternative tags the same span as MM (관형사, hanja-eligible) which has a 二 candidate — since
// that alternative's convertibleLength is larger (it "converts" 이 too), the wrong analysis won
// under the pre-fix convertibleLength-only selection.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi
import LibHangul
import XCTest
@testable import woorilee

@MainActor
final class HanjaContextJosaGuardTests: XCTestCase {
    // MARK: - Pure unit test (hand-built tokens, no Kiwi) — pins the bug

    /// Clause "배관이": result A (higher score) tags 이 as JKS (josa, non-eligible — no segment is
    /// ever created for it); result B (lower score) tags the same span as NR (수사, eligible) with
    /// a hanja candidate, giving it a larger convertibleLength under the pre-fix selection. Without
    /// the containment guard this test fails (B wins, 이 gets a segment with previewCandidate 二).
    func testBestRealtimeSegmentsRejectsLowerScoredAnalysisThatMistagsJosaAsEligible() {
        let clause = "배관이"
        let results = [
            TokenResult(
                score: -10,
                tokens: [
                    Token(form: "배관", tag: .nng, position: 0, length: 2),
                    Token(form: "이", tag: .jks, position: 2, length: 1),
                ]
            ),
            TokenResult(
                score: -20,
                tokens: [
                    Token(form: "배관", tag: .nng, position: 0, length: 2),
                    Token(form: "이", tag: .nr, position: 2, length: 1),
                ]
            ),
        ]

        let segments = KiwiAnalysisService.bestRealtimeSegments(
            from: results,
            in: clause,
            candidateLookup: { key in
                switch key {
                case "배관": return [candidate(reading: key, value: "配管")]
                case "이": return [candidate(reading: key, value: "二")]
                default: return []
                }
            }
        )

        XCTAssertEqual(segments.map(\.surface), ["배관"], "the josa 이 must not produce a segment at all")
        XCTAssertFalse(segments.contains { $0.surface == "이" })
    }

    // MARK: - Real-Kiwi regression (tightened from the diagnosis dump)

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

    private static func candidateLookup(_ key: String) -> [HanjaCandidate] {
        let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
        if !numericCandidates.isEmpty { return numericCandidates }

        guard let table = hanjaTable, let list = LibHangul.searchHanja(table: table, key: key) else { return [] }
        let seeds: [HanjaCandidateSeed] = (0..<list.getSize()).compactMap { i in
            guard let value = list.getNthValue(i) else { return nil }
            return HanjaCandidateSeed(reading: list.getNthKey(i) ?? key, value: value,
                                      comment: list.getNthComment(i) ?? "", source: .system, baseRank: i)
        }
        return mergeHanjaCandidates(userEntries: [], systemCandidates: seeds,
                                     usageCounts: [:], frequencyLookup: { _ in 0 })
    }

    /// The reported repro sentence: 이 (josa after 배관) must never carry a preview, and the
    /// content-word segments around it must still be produced.
    func testRealtimeAnalysisNeverConvertsJosaIAfterBaeGwan() throws {
        guard Self.kiwiModelsAvailable, let kiwi = Self.kiwi else {
            print("Kiwi model directory not found, skipping real-Kiwi josa guard regression.")
            return
        }
        XCTAssertNotNil(Self.hanjaTable, "hanja.txt failed to load")

        let clause = "수도 배관이 고장났다"
        let results = try kiwi.analyze(clause, topN: 3, options: KiwiAnalysisService.realtimeAnalysisMatchOptions)

        let segments = KiwiAnalysisService.bestRealtimeSegments(
            from: results, in: clause, candidateLookup: Self.candidateLookup, hangulUsageLookup: { _ in 0 }
        )

        for segment in segments where segment.surface == "이" {
            XCTAssertNil(segment.previewCandidate, "josa 이 must not be auto-converted to hanja")
        }
        XCTAssertFalse(
            segments.contains { $0.surface == "이" && $0.isConvertible },
            "josa 이 must not be exposed as a convertible segment at all"
        )

        XCTAssertTrue(segments.contains { $0.surface == "수도" }, "수도 segment must still exist")
        XCTAssertTrue(segments.contains { $0.surface == "배관" }, "배관 segment must still exist")
        XCTAssertTrue(segments.contains { $0.surface == "고장" }, "고장 segment must still exist")
    }

    // MARK: - Helpers

    private func candidate(reading: String, value: String) -> HanjaCandidate {
        HanjaCandidate(reading: reading, value: value, comment: "", source: .system,
                       usageCount: 0, frequency: 0, baseRank: 0)
    }
}
