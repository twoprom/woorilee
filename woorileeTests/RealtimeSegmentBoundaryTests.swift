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

    func testBoundarySelectionAndCommitPreserveUnrelatedHangul() {
        let source = "한국은 집이 화려"
        let values = ["한국": ["韓國"], "한": ["漢", "閑"], "국": ["國"],
                      "은": ["銀"], "집": ["集"], "이": ["二"], "화려": ["華麗"]]
        let lookup: (String) -> [HanjaCandidate] = { key in
            (values[key] ?? []).map { self.candidate(reading: key, value: $0) }
        }
        let automatic = KiwiAnalysisService.makeRealtimeSegments(
            from: [
                Token(form: "한국", tag: .nnp, position: 0, length: 2),
                Token(form: "은", tag: .jx, position: 2, length: 1),
                Token(form: "집", tag: .nng, position: 4, length: 1),
                Token(form: "이", tag: .jks, position: 5, length: 1),
                Token(form: "화려", tag: .xr, position: 7, length: 2),
            ],
            in: source, candidateLookup: lookup,
            autoConvertGate: { candidate, _ in candidate.reading != "화려" },
            nativeHomographLookup: { $0 == "집" }
        )
        let session = InputSession()
        session.appendRawTextToRealtimeClause(source)
        session.updateRealtimeAnalysis(segments: automatic)
        XCTAssertEqual(session.realtimeDisplayText, "韓國은 집이 화려")
        let client = FakeIMKTextInput()
        var usage: [PendingHanjaUsageEvent] = []
        let engine = InputCompositionEngine(
            client: client, session: session,
            analyzeRealtimeClause: { _, _, _ in
                XCTFail("Manual boundary edits must not rerun automatic analysis")
                return RealtimeClauseAnalysis(segments: automatic, clauseContentFeatures: [])
            },
            analyzeManualClause: { text, boundaries in
                KiwiAnalysisService.makeManualSegments(boundaries: boundaries, in: text, candidateLookup: lookup)
            },
            rankManualClause: { segments, previous, inputs in
                rankManualSegments(segments, previousSegments: previous, candidateLookup: lookup, sessionInputs: inputs)
            },
            flushRealtimeUsageEvents: { usage += $0 }, updateComposition: {}, debugLog: { _ in }
        )

        XCTAssertTrue(session.adjustRealtimeSegmentBoundary(byCharacters: -1))
        engine.updateDisplay()
        XCTAssertEqual(session.realtimeDisplayText, "漢국은 집이 화려")
        XCTAssertTrue(session.applyRealtimeCandidateSelection(lookup("한")[1]))
        engine.updateDisplay()
        XCTAssertEqual(session.realtimeDisplayText, "閑국은 집이 화려")
        engine.updateDisplay()
        XCTAssertEqual(session.realtimeDisplayText, "閑국은 집이 화려")

        engine.commitCurrentComposition()

        XCTAssertEqual(client.insertCalls.map(\.text), ["閑국은 집이 화려"])
        XCTAssertEqual(usage.map(\.lookupKey), ["한"])
        XCTAssertEqual(usage.map(\.value), ["閑"])
    }

    func testRepeatedBoundaryEditsPreserveUnrelatedPreviewAndExplicitHangulChoice() {
        let source = "수도 한국 역사"
        let values = ["수도": ["首都", "水道"], "한국": ["韓國"], "한": ["漢"],
                      "국": ["國"], "역사": ["歷史"]]
        let lookup: (String) -> [HanjaCandidate] = { key in
            (values[key] ?? []).map { self.candidate(reading: key, value: $0) }
        }
        var state = makeAutoState(raw: source, tokens: [
            Token(form: "수도", tag: .nng, position: 0, length: 2),
            Token(form: "한국", tag: .nnp, position: 3, length: 2),
            Token(form: "역사", tag: .nng, position: 6, length: 2),
        ], lookup: lookup)
        // Context can select a different preview from the manual dictionary's first candidate.
        state.updateAnalysis(segments: state.segments.map { segment in
            segment.surface == "수도" ? segment.replacingPreviewCandidate(lookup("수도")[1]) : segment
        })
        state.selectedSegmentIndex = 2
        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())
        state.selectedSegmentIndex = 1
        state.seedManualBoundariesIfNeeded()

        for delta in [-1, 1, -1] {
            XCTAssertTrue(state.adjustFocusedBoundary(byCharacters: delta))
            let manual = KiwiAnalysisService.makeManualSegments(
                boundaries: state.manualBoundaries ?? [], in: source, candidateLookup: lookup)
            state.updateAnalysis(segments: rankManualSegments(
                manual, previousSegments: state.automaticContextSegments, candidateLookup: lookup))

            XCTAssertEqual(state.segments.first { $0.surface == "수도" }?.previewCandidate?.value, "水道")
            XCTAssertNil(state.segments.first { $0.surface == "역사" }?.previewCandidate)
            XCTAssertEqual(state.previewClauseText, delta == -1 ? "水道 漢국 역사" : "水道 韓國 역사")
        }
    }

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
