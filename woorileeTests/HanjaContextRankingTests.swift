// Tests for the step 4a context scoring: buildDominantHanjaMap + rankWithContext.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/context-aware-hanja-conversion.md §5 (단계 4 — 사전 내부 문맥 신호). This file
// hand-feeds context (no Kiwi) to pin the flagship 수도 behavior validated against real dictionary
// data: 上下水道 contains 水道, 修道院 contains 修道, and 大韓民國 contains none of the 수도 candidates
// (so frequency default — 首都 — wins).

import XCTest
@testable import woorilee

final class HanjaContextRankingTests: XCTestCase {
    // Decoded freq-hanjaeo.txt values for reading 수도 (§0 실측): 首都 11750 > 修道 2737 > 水道 2106.
    private func makeSudoCandidates() -> [HanjaCandidate] {
        [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]
    }

    func testContainmentOverridesFrequencyForWaterPipeContext() {
        let ranked = rankWithContext(
            candidates: makeSudoCandidates(),
            contextDominantHanja: ["上下水道"],
            weights: .default
        )
        XCTAssertEqual(ranked.first?.value, "水道")
    }

    func testContainmentOverridesFrequencyForMonasteryContext() {
        let ranked = rankWithContext(
            candidates: makeSudoCandidates(),
            contextDominantHanja: ["修道院"],
            weights: .default
        )
        XCTAssertEqual(ranked.first?.value, "修道")
    }

    func testNoApplicableContextFallsBackToFrequencyDefault() {
        let rankedWithEmptyContext = rankWithContext(
            candidates: makeSudoCandidates(),
            contextDominantHanja: [],
            weights: .default
        )
        XCTAssertEqual(rankedWithEmptyContext.first?.value, "首都")

        // 大韓民國 shares no substring with, and does not contain, any of 首都/修道/水道.
        let rankedWithUnrelatedContext = rankWithContext(
            candidates: makeSudoCandidates(),
            contextDominantHanja: ["大韓民國"],
            weights: .default
        )
        XCTAssertEqual(rankedWithUnrelatedContext.first?.value, "首都")
    }

    func testBuildDominantHanjaMapSingleCandidateReadingMapsToIt() {
        let map = buildDominantHanjaMap(
            dictionaryLines: ["상하수도:上下水道:"],
            frequency: { _ in 0 }
        )
        XCTAssertEqual(map["상하수도"], "上下水道")
    }

    func testBuildDominantHanjaMapDominantFrequencyMapsToTopCandidate() {
        // Top freq 100 >= 5 * runner-up 20 → dominates.
        let map = buildDominantHanjaMap(
            dictionaryLines: ["가상읽기:壓倒的:", "가상읽기:第二:"],
            frequency: { $0 == "壓倒的" ? 100 : 20 },
            dominanceRatio: 5
        )
        XCTAssertEqual(map["가상읽기"], "壓倒的")
    }

    func testBuildDominantHanjaMapAmbiguousReadingIsAbsent() {
        // Top freq 100 < 5 * runner-up 60 → does not dominate; matches real 수도 (top 11750 <
        // 5 * runner-up 2737 = 13685), which is why 수도 itself has no single dominant hanja.
        let map = buildDominantHanjaMap(
            dictionaryLines: ["공사:工事:", "공사:公社:"],
            frequency: { $0 == "工事" ? 100 : 60 }
        )
        XCTAssertNil(map["공사"])
    }
}
