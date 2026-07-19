// Tests for the context-aware Hanja candidate ranking interface.
//     Copyright (C) 2026 Seungjin Lee.

import Kiwi
import XCTest
@testable import woorilee

final class HanjaContextRankerTests: XCTestCase {
    /// Scrambled order exercising every tie-break level of `compareHanjaCandidate`:
    /// source (userDefined first) → usageCount desc → frequency desc → baseRank asc → value asc → reading asc.
    private func makeScrambledCandidates() -> [HanjaCandidate] {
        [
            // Differ only by reading (last tie-break level).
            HanjaCandidate(reading: "나", value: "他", comment: "", source: .system, usageCount: 0, frequency: 0, baseRank: 0),
            HanjaCandidate(reading: "가", value: "他", comment: "", source: .system, usageCount: 0, frequency: 0, baseRank: 0),
            // Differ only by value (second-to-last tie-break level).
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 5, baseRank: 2),
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 5, baseRank: 2),
            // Differ only by baseRank.
            HanjaCandidate(reading: "공사", value: "工事", comment: "", source: .system, usageCount: 0, frequency: 3, baseRank: 4),
            HanjaCandidate(reading: "공사", value: "公社", comment: "", source: .system, usageCount: 0, frequency: 3, baseRank: 1),
            // Differ only by frequency.
            HanjaCandidate(reading: "연기", value: "延期", comment: "", source: .system, usageCount: 0, frequency: 10, baseRank: 0),
            HanjaCandidate(reading: "연기", value: "煙氣", comment: "", source: .system, usageCount: 0, frequency: 50, baseRank: 0),
            // Differ only by usageCount.
            HanjaCandidate(reading: "사과", value: "沙果", comment: "", source: .system, usageCount: 1, frequency: 20, baseRank: 0),
            HanjaCandidate(reading: "사과", value: "謝過", comment: "", source: .system, usageCount: 7, frequency: 20, baseRank: 0),
            // Differ only by source — userDefined must win regardless of other fields.
            HanjaCandidate(reading: "의사", value: "醫師", comment: "", source: .system, usageCount: 100, frequency: 100, baseRank: 0),
            HanjaCandidate(reading: "의사", value: "議事", comment: "", source: .userDefined, usageCount: 0, frequency: 0, baseRank: 99),
        ]
    }

    func testRankWithContextMatchesCompareHanjaCandidateWhenContextIsEmpty() {
        let candidates = makeScrambledCandidates()
        let reference = candidates.sorted(by: compareHanjaCandidate)

        let ranked = rankWithContext(candidates: candidates, contextDominantHanja: [], weights: .default)

        XCTAssertEqual(ranked.map(\.value), reference.map(\.value))
        XCTAssertEqual(ranked.map(\.source), reference.map(\.source))
    }

    /// A non-empty context that shares no hanja character with, and does not contain, any test
    /// candidate's value must still leave the order untouched — the "no applicable context ⇒
    /// identical to compareHanjaCandidate" invariant must hold beyond the empty-context case.
    func testRankWithContextIgnoresContextThatSharesNothingWithAnyCandidate() {
        let candidates = makeScrambledCandidates()
        let reference = candidates.sorted(by: compareHanjaCandidate)

        let rankedWithContext = rankWithContext(
            candidates: candidates,
            contextDominantHanja: ["無關性"],
            weights: .default
        )

        XCTAssertEqual(rankedWithContext.map(\.value), reference.map(\.value))
        XCTAssertEqual(rankedWithContext.map(\.source), reference.map(\.source))
    }

    // MARK: - Step 5c: association axis (docs/plans/context-aware-hanja-conversion.md §7 5c)

    // Decoded freq-hanjaeo.txt values for reading 수도 (§0 실측): 首都 11750 > 修道 2737 > 水道 2106.
    private func sudoCandidatesByFrequency() -> [HanjaCandidate] {
        [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]
    }

    /// Explicit empty `associationScores` must be indistinguishable from the omitted-default case:
    /// no applicable context (containment or association) ⇒ EXACTLY `compareHanjaCandidate` order.
    func testRankWithContextWithEmptyAssociationScoresMatchesCompareHanjaCandidate() {
        let candidates = makeScrambledCandidates()
        let reference = candidates.sorted(by: compareHanjaCandidate)

        let ranked = rankWithContext(
            candidates: candidates,
            contextDominantHanja: [],
            associationScores: [:],
            weights: .default
        )

        XCTAssertEqual(ranked.map(\.value), reference.map(\.value))
    }

    /// Flip test: a single matched association feature (집/NNG weight 37, the real bundled value —
    /// see HanjaContextAssociationStoreTests) must overcome the 首都/水道 frequency gap (11,750 −
    /// 2,106 = 9,644) at the default association weight (300): 37 × 300 = 11,100 > 9,644.
    func testAssociationScoreFlipsFrequencyLeaderWhenNoContainmentApplies() {
        let ranked = rankWithContext(
            candidates: sudoCandidatesByFrequency(),
            contextDominantHanja: [],
            associationScores: ["水道": 37],
            weights: .default
        )

        XCTAssertEqual(ranked.first?.value, "水道")
    }

    /// Containment must always dominate association, even when association scoring points at a
    /// different candidate with a near-maximal realistic sum (~30 features × 255 ≈ 7,650).
    func testContainmentAlwaysOutranksAssociation() {
        let ranked = rankWithContext(
            candidates: sudoCandidatesByFrequency(),
            contextDominantHanja: ["上下水道"],
            associationScores: ["首都": 7_650],
            weights: .default
        )

        XCTAssertEqual(ranked.first?.value, "水道", "containment (10,000,000) must outrank even a maximal association sum (~2.3M)")
    }

    // MARK: - Context-first ordering + NNP gazette bonus (2026-07-18 user directives)

    /// Context evidence must outrank every personalization tier: a plain system candidate with an
    /// association hit beats a userDefined candidate AND a heavily-used candidate that carry no
    /// context evidence (the old fold-into-frequency scheme could never do this — source and
    /// usageCount compared before frequency).
    func testContextBoostOutranksUsageCountAndUserDefined() {
        let candidates = [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .userDefined, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 50, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]

        let ranked = rankWithContext(
            candidates: candidates,
            contextDominantHanja: [],
            associationScores: ["水道": 37],
            weights: .default
        )

        XCTAssertEqual(ranked.first?.value, "水道", "context evidence must outrank userDefined/usageCount tiers")
        // Ties (boost 0) among the rest still follow compareHanjaCandidate: userDefined first.
        XCTAssertEqual(ranked.map(\.value), ["水道", "首都", "修道"])
    }

    // 조선 실측 (2026-07-18, "서울은 조선의 수도였다"): 造船 3,824 > 朝鮮 1,093 > 祖先 101;
    // association 祖先 수도/NNG=66 (노이즈), 朝鮮 서울/NNP=24; only 朝鮮 has a hanja.txt comment.
    private func chosunCandidates() -> [HanjaCandidate] {
        [
            HanjaCandidate(reading: "조선", value: "造船", comment: "", source: .system, usageCount: 0, frequency: 3824, baseRank: 0),
            HanjaCandidate(reading: "조선", value: "朝鮮", comment: "조선민주주의인민공화국", source: .system, usageCount: 0, frequency: 1093, baseRank: 1),
            HanjaCandidate(reading: "조선", value: "祖先", comment: "", source: .system, usageCount: 0, frequency: 101, baseRank: 2),
        ]
    }

    /// NNP gazette bonus flagship: 朝鮮 (assoc 24 + comment bonus 100 → 24×300 + 30,000 = 37,200)
    /// must beat 祖先's corpus noise (66×300 = 19,800) when the segment is tagged NNP.
    func testNnpGazetteBonusLiftsCommentedProperNounOverNoise() {
        let ranked = rankWithContext(
            candidates: chosunCandidates(),
            contextDominantHanja: [],
            associationScores: ["祖先": 66, "朝鮮": 24],
            weights: .default,
            segmentTag: .nnp
        )

        XCTAssertEqual(ranked.first?.value, "朝鮮")
    }

    /// The same inputs WITHOUT the NNP tag get no bonus — 祖先's larger association score wins
    /// (this is exactly the 2026-07-18 defect ordering, preserved for non-proper-noun segments).
    func testNoGazetteBonusForNonNnpTag() {
        let ranked = rankWithContext(
            candidates: chosunCandidates(),
            contextDominantHanja: [],
            associationScores: ["祖先": 66, "朝鮮": 24],
            weights: .default,
            segmentTag: .nng
        )

        XCTAssertEqual(ranked.first?.value, "祖先")
    }

    /// A strong real association (造船 중공업/NNG=173 → 51,900) must beat the gazette bonus
    /// (朝鮮 24×300 + 30,000 = 37,200) — the bonus is a prior, not a trump card.
    func testStrongAssociationOutranksGazetteBonus() {
        let ranked = rankWithContext(
            candidates: chosunCandidates(),
            contextDominantHanja: [],
            associationScores: ["造船": 173, "朝鮮": 24],
            weights: .default,
            segmentTag: .nnp
        )

        XCTAssertEqual(ranked.first?.value, "造船")
    }
}
