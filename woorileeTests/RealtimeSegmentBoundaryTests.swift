// Tests for realtime segment boundary adjustment (Japanese-IME style 文節 신축).
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeSegmentBoundaryTests: XCTestCase {
    // MARK: - Seed

    func testSeedBuildsFullPartitionFromSegments() {
        var state = makeAutoState(
            raw: "한국 역사",
            tokens: [
                Token(form: "한국", tag: .nnp, position: 0, length: 2),
                Token(form: "역사", tag: .nng, position: 3, length: 2),
            ],
            lookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )

        state.seedManualBoundariesIfNeeded()

        XCTAssertTrue(state.isManualSegmentation)
        XCTAssertEqual(state.manualBoundaries, [2, 3])
        XCTAssertEqual(state.focusedSpanStart, 0)
    }

    func testSeedIsNoOpWhenAlreadyManual() {
        var state = RealtimeClauseState()
        state.rawClauseText = "한국역사"
        state.manualBoundaries = [1]
        state.focusedSpanStart = 0

        state.seedManualBoundariesIfNeeded()

        XCTAssertEqual(state.manualBoundaries, [1])
    }

    // MARK: - Expand / Shrink

    func testExpandFocusedSpanGrowsRightBoundary() {
        var state = makeManualState(raw: "한국역사", boundaries: [2], focus: 0)

        XCTAssertTrue(state.adjustFocusedBoundary(byCharacters: 1))
        XCTAssertEqual(state.manualBoundaries, [3])

        let segments = KiwiAnalysisService.makeManualSegments(
            boundaries: state.manualBoundaries ?? [],
            in: "한국역사",
            candidateLookup: { _ in [] }
        )
        XCTAssertEqual(segments.map(\.surface), ["한국역", "사"])
    }

    func testShrinkFocusedSpanMovesRightBoundaryLeft() {
        var state = makeManualState(raw: "한국역사", boundaries: [3], focus: 0)

        XCTAssertTrue(state.adjustFocusedBoundary(byCharacters: -1))
        XCTAssertEqual(state.manualBoundaries, [2])
    }

    func testExpandLastSpanIsNoOp() {
        var state = makeManualState(
            raw: "한국역사",
            boundaries: [2],
            focus: 2,
            lookup: { _ in [candidate(reading: "x", value: "X")] }
        )

        XCTAssertEqual(state.selectedSegment?.surface, "역사")
        XCTAssertFalse(state.adjustFocusedBoundary(byCharacters: 1))
        XCTAssertEqual(state.manualBoundaries, [2])
    }

    func testShrinkLengthOneSpanIsNoOp() {
        var state = makeManualState(raw: "한국역사", boundaries: [2, 3], focus: 3)

        XCTAssertEqual(state.selectedSegment?.surface, "사")
        XCTAssertFalse(state.adjustFocusedBoundary(byCharacters: -1))
        XCTAssertEqual(state.manualBoundaries, [2, 3])
    }

    func testShrinkLastSpanCreatesNewBoundary() {
        var state = makeManualState(
            raw: "한국역사",
            boundaries: [2],
            focus: 2,
            lookup: { _ in [candidate(reading: "x", value: "X")] }
        )

        XCTAssertTrue(state.adjustFocusedBoundary(byCharacters: -1))
        XCTAssertEqual(state.manualBoundaries, [2, 3])
    }

    func testExpandMergesWhenNeighborSpanVanishes() {
        var state = makeManualState(raw: "한국역사", boundaries: [2, 3], focus: 0)

        XCTAssertTrue(state.adjustFocusedBoundary(byCharacters: 1))
        XCTAssertEqual(state.manualBoundaries, [3])
    }

    // MARK: - Numeric spans

    func testNumericSpansSplitByBoundary() {
        let segments = KiwiAnalysisService.makeManualSegments(
            boundaries: [2, 4],
            in: "한국123",
            candidateLookup: { key in
                if let normalized = NumericHanjaCandidateGenerator.normalizedDigits(from: key) {
                    return NumericHanjaCandidateGenerator.candidates(for: normalized)
                }

                return key == "한국" ? [candidate(reading: key, value: "韓國")] : []
            }
        )

        XCTAssertEqual(segments.map(\.surface), ["한국", "12", "3"])
        XCTAssertEqual(segments.map(\.normalizedLookupKey), ["한국", "12", "3"])
        XCTAssertEqual(segments.map(\.isConvertible), [true, true, true])
        XCTAssertEqual(segments[0].previewCandidate?.value, "韓國")
        XCTAssertNil(segments[1].previewCandidate)
        XCTAssertNil(segments[2].previewCandidate)
    }

    // MARK: - Selection

    func testNonConvertibleFocusSpanKeepsSelection() {
        let state = makeManualState(
            raw: "한국역사",
            boundaries: [3],
            focus: 0,
            lookup: { key in key == "한국" ? [candidate(reading: key, value: "韓國")] : [] }
        )

        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertEqual(state.selectedSegment?.surface, "한국역")
        XCTAssertEqual(state.selectedSegment?.isConvertible, false)
    }

    func testManualNavigationSyncsFocusedSpanStart() {
        var state = makeManualState(
            raw: "한국 역사",
            boundaries: [2, 3],
            focus: 0,
            lookup: { key in
                switch key {
                case "한국": return [candidate(reading: key, value: "韓國")]
                case "역사": return [candidate(reading: key, value: "歷史")]
                default: return []
                }
            }
        )

        XCTAssertEqual(state.selectedSegmentIndex, 0)
        XCTAssertTrue(state.moveSelectedSegment(by: 1))
        XCTAssertEqual(state.selectedSegment?.surface, "역사")
        XCTAssertEqual(state.focusedSpanStart, 3)
    }

    // MARK: - Lifecycle

    func testClearManualSegmentationReturnsToAutoPath() {
        var state = makeManualState(raw: "한국역사", boundaries: [2], focus: 0)

        state.clearManualSegmentation()

        XCTAssertFalse(state.isManualSegmentation)
        XCTAssertNil(state.manualBoundaries)
        XCTAssertNil(state.focusedSpanStart)

        let autoSegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [Token(form: "한국", tag: .nnp, position: 0, length: 2)],
            in: "한국역사",
            candidateLookup: { key in key == "한국" ? [candidate(reading: key, value: "韓國")] : [] }
        )
        state.updateAnalysis(segments: autoSegments)

        XCTAssertEqual(state.previewClauseText, "韓國역사")
        XCTAssertEqual(state.selectedSegment?.surface, "한국")
    }

    // MARK: - Helpers

    private func makeAutoState(
        raw: String,
        tokens: [Token],
        lookup: (String) -> [HanjaCandidate]
    ) -> RealtimeClauseState {
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: raw,
            candidateLookup: lookup
        )
        var state = RealtimeClauseState()
        state.rawClauseText = raw
        state.updateAnalysis(segments: segments)
        return state
    }

    private func makeManualState(
        raw: String,
        boundaries: [Int],
        focus: Int,
        lookup: (String) -> [HanjaCandidate] = { _ in [] }
    ) -> RealtimeClauseState {
        var state = RealtimeClauseState()
        state.rawClauseText = raw
        state.manualBoundaries = boundaries
        state.focusedSpanStart = focus
        let segments = KiwiAnalysisService.makeManualSegments(
            boundaries: boundaries,
            in: raw,
            candidateLookup: lookup
        )
        state.updateAnalysis(segments: segments)
        return state
    }

    private func candidate(reading: String, value: String, usageCount: Int = 0) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: "",
            source: .system,
            usageCount: usageCount,
            frequency: 0,
            baseRank: 0
        )
    }
}
