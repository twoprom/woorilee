// Tests for step R2-1: pure joint candidate selection across a clause's target segments.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/hanja-context-scaling-plan.md §7. Exercises `associationProfileSimilarity` and
// `selectJointAssignment` directly, with hand-built inputs (no Kiwi, no real association table —
// that integration lives in RealtimeContextRankingTests.swift).

import Kiwi
import XCTest
@testable import woorilee

final class HanjaClauseJointSelectionTests: XCTestCase {
    // MARK: - associationProfileSimilarity

    func testIdenticalProfilesHaveCosineOne() {
        let profile = ["a/NNG": 10.0, "b/NNG": 20.0, "c/NNG": 30.0, "d/NNG": 40.0, "e/NNG": 50.0]
        XCTAssertEqual(associationProfileSimilarity(profile, profile), 1.0, accuracy: 1e-9)
    }

    func testNoOverlapIsZero() {
        let lhs = ["a/NNG": 1.0, "b/NNG": 2.0, "c/NNG": 3.0, "d/NNG": 4.0, "e/NNG": 5.0]
        let rhs = ["f/NNG": 1.0, "g/NNG": 2.0, "h/NNG": 3.0, "i/NNG": 4.0, "j/NNG": 5.0]
        XCTAssertEqual(associationProfileSimilarity(lhs, rhs), 0)
    }

    /// Guard: fewer than `minimumSharedFeatures` (default 5) shared entries is a false-positive
    /// risk (coordinator's 2026-07-25 measurement — small 3~4-feature profiles score cos
    /// 0.23~0.30 spuriously), so it must be forced to 0 even though the raw cosine is positive.
    func testFourSharedFeaturesIsZeroedByGuard() {
        let lhs = ["a/NNG": 1.0, "b/NNG": 1.0, "c/NNG": 1.0, "d/NNG": 1.0, "onlyLhs/NNG": 1.0]
        let rhs = ["a/NNG": 1.0, "b/NNG": 1.0, "c/NNG": 1.0, "d/NNG": 1.0, "onlyRhs/NNG": 1.0]
        XCTAssertEqual(associationProfileSimilarity(lhs, rhs), 0, "4 shared features must be guarded to 0")
    }

    func testFiveSharedFeaturesIsPositive() {
        let lhs = ["a/NNG": 1.0, "b/NNG": 1.0, "c/NNG": 1.0, "d/NNG": 1.0, "e/NNG": 1.0, "onlyLhs/NNG": 1.0]
        let rhs = ["a/NNG": 1.0, "b/NNG": 1.0, "c/NNG": 1.0, "d/NNG": 1.0, "e/NNG": 1.0, "onlyRhs/NNG": 1.0]
        XCTAssertGreaterThan(associationProfileSimilarity(lhs, rhs), 0)
    }

    func testSimilarityIsCommutative() {
        let lhs = ["a/NNG": 3.0, "b/NNG": 7.0, "c/NNG": 2.0, "d/NNG": 9.0, "e/NNG": 4.0, "onlyLhs/NNG": 1.0]
        let rhs = ["a/NNG": 5.0, "b/NNG": 1.0, "c/NNG": 6.0, "d/NNG": 2.0, "e/NNG": 8.0, "onlyRhs/NNG": 1.0]
        XCTAssertEqual(associationProfileSimilarity(lhs, rhs), associationProfileSimilarity(rhs, lhs), accuracy: 1e-9)
    }

    func testEmptyProfileIsZero() {
        let nonEmpty = ["a/NNG": 1.0, "b/NNG": 1.0, "c/NNG": 1.0, "d/NNG": 1.0, "e/NNG": 1.0]
        XCTAssertEqual(associationProfileSimilarity([:], nonEmpty), 0)
        XCTAssertEqual(associationProfileSimilarity(nonEmpty, [:]), 0)
        XCTAssertEqual(associationProfileSimilarity([:], [:]), 0)
    }

    // MARK: - selectJointAssignment: identity invariant (all pairBonus == 0 ⇒ independent argmax)

    func testAllZeroPairBonusReproducesIndependentArgmaxForOneToFiveSegments() {
        for segmentCount in 1...5 {
            let segments = (0..<segmentCount).map { _ in
                HanjaJointSegmentInput(boosts: [30, 20, 10], profiles: [[:], [:], [:]])
            }
            let result = selectJointAssignment(segments: segments) { _, _, _, _ in 0 }
            XCTAssertEqual(result, [Int](repeating: 0, count: segmentCount), "segmentCount=\(segmentCount)")
        }
    }

    // MARK: - Edge cases

    func testSingleSegmentReturnsZeroIndex() {
        let segments = [HanjaJointSegmentInput(boosts: [100, 50], profiles: [[:], [:]])]
        // pairBonus is never called for a single segment, but supply a trapping closure anyway to
        // prove it — a bug that started calling it with i == j would be caught immediately.
        let result = selectJointAssignment(segments: segments) { _, _, _, _ in
            XCTFail("pairBonus must not be invoked for a single segment")
            return 0
        }
        XCTAssertEqual(result, [0])
    }

    func testEmptyInputReturnsEmptyAssignment() {
        let result = selectJointAssignment(segments: []) { _, _, _, _ in 0 }
        XCTAssertEqual(result, [])
    }

    /// More than `HanjaJointSelectionLimits.maxSegments` participating segments must fall back to
    /// the independent argmax defensively (the real caller is expected to skip PASS 2 entirely in
    /// this case — see KiwiAnalysisService.applyContextReranking).
    func testMoreThanMaxSegmentsFallsBackToIndependentArgmax() {
        let segmentCount = HanjaJointSelectionLimits.maxSegments + 1
        let segments = (0..<segmentCount).map { _ in
            HanjaJointSegmentInput(boosts: [30, 20, 10], profiles: [[:], [:], [:]])
        }
        let result = selectJointAssignment(segments: segments) { _, _, _, _ in 1_000_000 }
        XCTAssertEqual(result, [Int](repeating: 0, count: segmentCount))
    }

    // MARK: - Joint effect: a positive pairBonus can override the independent argmax

    /// Two segments, each with boosts [10, 9] (independent argmax = [0, 0], score 20). A single
    /// positive pairBonus(0, 1, 1, 1) = 5 makes [1, 1] score 9 + 9 + 5 = 23 > 20, so the joint
    /// search must pick [1, 1] instead.
    func testPositivePairBonusOverridesIndependentArgmax() {
        let segments = [
            HanjaJointSegmentInput(boosts: [10, 9], profiles: [[:], [:]]),
            HanjaJointSegmentInput(boosts: [10, 9], profiles: [[:], [:]]),
        ]
        let result = selectJointAssignment(segments: segments) { i, ci, j, cj in
            (i == 0 && ci == 1 && j == 1 && cj == 1) || (i == 1 && ci == 1 && j == 0 && cj == 1) ? 5 : 0
        }
        XCTAssertEqual(result, [1, 1])
    }

    /// Same shape as above, but pairBonus is exactly 0 everywhere — the independent argmax [0, 0]
    /// must be preserved (ties never override, per the strict-`>` update rule).
    func testZeroPairBonusPreservesIndependentArgmaxForTwoSegments() {
        let segments = [
            HanjaJointSegmentInput(boosts: [10, 9], profiles: [[:], [:]]),
            HanjaJointSegmentInput(boosts: [10, 9], profiles: [[:], [:]]),
        ]
        let result = selectJointAssignment(segments: segments) { _, _, _, _ in 0 }
        XCTAssertEqual(result, [0, 0])
    }

    // MARK: - rankWithContextScored == rankWithContext (R2-1 exposure invariant)

    /// `rankWithContext` must remain EXACTLY `rankWithContextScored(...).map(\.candidate)` — the
    /// spec's stated reason for splitting the function. Exercised over several fixed candidate
    /// sets covering empty/non-empty context, association scores, NNP tag, and session boosts.
    func testRankWithContextIsScoredVariantMappedToCandidates() {
        let candidates = [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]

        let fixtures: [(context: [String], scores: [String: Double], tag: POSTag?, sessionBoosts: [String: Double])] = [
            (context: [], scores: [:], tag: nil, sessionBoosts: [:]),
            (context: ["上下水道"], scores: [:], tag: nil, sessionBoosts: [:]),
            (context: [], scores: ["水道": 37], tag: nil, sessionBoosts: [:]),
            (context: [], scores: ["水道": 37, "首都": 5], tag: .nnp, sessionBoosts: [:]),
            (context: [], scores: [:], tag: nil, sessionBoosts: ["修道": 12]),
        ]

        for fixture in fixtures {
            let scoredResult = rankWithContextScored(
                candidates: candidates,
                contextDominantHanja: fixture.context,
                associationScores: fixture.scores,
                weights: .default,
                segmentTag: fixture.tag,
                sessionBoosts: fixture.sessionBoosts
            )
            let plainResult = rankWithContext(
                candidates: candidates,
                contextDominantHanja: fixture.context,
                associationScores: fixture.scores,
                weights: .default,
                segmentTag: fixture.tag,
                sessionBoosts: fixture.sessionBoosts
            )
            XCTAssertEqual(scoredResult.map(\.candidate), plainResult, "fixture=\(fixture)")
        }
    }
}
