// Tests for realtime Hanja commit and cancel matrix.
//     Copyright (C) 2026 Seungjin Lee.

// Locks the realtime Hanja commit/cancel matrix from
// hanja-implementation-plan.md step 8 and the flush/drop table in
// hanja-implementation-plan-plus.md section 5.3.
//
// Modes (R = realtime active, C = clause non-empty, P = candidate panel open):
//   Return: !R,!H → passthrough; !R,H → commit preedit;
//           R,!C → passthrough; R,C,!P → clause commit + flush usage;
//           R,C,P → candidate select (panel-state tests).
//   Escape: R,C,!P → cancel clause + drop usage;
//           R,C,P → panel close (clause + usage preserved).
//   Space:  R,C,!P → preedit flush → append " " + re-analyze;
//           R,C,P → panel close → same.
//   Backspace: R,C → preedit > rawClause > cancel cascade.
//   Tab:    R,C,P → next page; Shift+Tab → previous page.
//   Left/Right: R,C → prev/next convertible segment.

import AppKit
import InputMethodKit
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeHanjaCommitCancelTests: XCTestCase {
    func testCommitRealtimeClauseFlushesPendingUsageAndInsertsPreview() {
        let harness = makeHarness(rawText: "한국")
        harness.session.applyRealtimeCandidateSelection(harness.selectedCandidate)
        XCTAssertEqual(harness.session.realtimeClauseState.pendingUsageEvents.map(\.value), ["漢國"])

        harness.engine.commitCurrentComposition()

        XCTAssertEqual(harness.client.insertCalls.map(\.text), ["漢國"])
        XCTAssertEqual(harness.flushedBatches.count, 1)
        XCTAssertEqual(harness.flushedBatches.first?.map(\.value), ["漢國"])
        XCTAssertEqual(harness.session.compositionMode, .hangul)
        XCTAssertFalse(harness.session.hasRealtimeClause)
        XCTAssertTrue(harness.session.realtimeClauseState.pendingUsageEvents.isEmpty)
    }

    func testCommitRealtimeClauseWithoutPendingEventsFlushesEmptyArray() {
        let harness = makeHarness(rawText: "한국")
        XCTAssertTrue(harness.session.realtimeClauseState.pendingUsageEvents.isEmpty)

        harness.engine.commitCurrentComposition()

        XCTAssertEqual(harness.client.insertCalls.map(\.text), ["韓國"])
        XCTAssertEqual(harness.flushedBatches.count, 1)
        XCTAssertTrue(harness.flushedBatches.first?.isEmpty ?? false)
        XCTAssertEqual(harness.session.compositionMode, .hangul)
    }

    func testCancelRealtimeClauseDropsPendingUsageAndSkipsInsertText() {
        let harness = makeHarness(rawText: "한국")
        harness.session.applyRealtimeCandidateSelection(harness.selectedCandidate)
        XCTAssertFalse(harness.session.realtimeClauseState.pendingUsageEvents.isEmpty)

        harness.engine.cancelRealtimeComposition()

        XCTAssertTrue(harness.client.insertCalls.isEmpty)
        XCTAssertTrue(harness.flushedBatches.isEmpty)
        XCTAssertEqual(harness.session.compositionMode, .hangul)
        XCTAssertFalse(harness.session.hasRealtimeClause)
        XCTAssertEqual(harness.session.realtimeClauseState, RealtimeClauseState())
    }

    func testCancelOutsideRealtimeModeStillResetsSession() {
        let session = InputSession()
        XCTAssertTrue(session.process("g"))
        XCTAssertTrue(session.process("k"))
        let client = FakeIMKTextInput()
        let engine = makeEngine(client: client, session: session)

        XCTAssertEqual(session.compositionMode, .hangul)
        engine.cancelRealtimeComposition()

        XCTAssertEqual(session.preeditText, "")
        XCTAssertEqual(session.compositionMode, .hangul)
    }

    func testCommitOutsideRealtimeModeFlushesPreeditNotUsage() {
        let session = InputSession()
        XCTAssertTrue(session.process("g"))
        XCTAssertTrue(session.process("k"))
        XCTAssertTrue(session.process("s"))
        let client = FakeIMKTextInput()
        let flushed = FlushSink()
        let engine = makeEngine(
            client: client,
            session: session,
            flushRealtimeUsageEvents: { flushed.batches.append($0) }
        )

        engine.commitCurrentComposition()

        XCTAssertEqual(client.insertCalls.map(\.text), ["한"])
        XCTAssertTrue(flushed.batches.isEmpty, "Hangul-mode commit must not invoke usage flush hook")
    }

    func testCommitRealtimeFlushesPendingPreeditIntoClauseBeforeUsageFlush() {
        let harness = makeHarness(rawText: "한")
        XCTAssertTrue(harness.session.process("r"))
        harness.session.syncRealtimeTailPreedit()
        XCTAssertEqual(harness.session.realtimeClauseState.tailPreedit, "ㄱ")

        harness.engine.commitCurrentComposition()

        XCTAssertEqual(harness.client.insertCalls.count, 1)
        XCTAssertEqual(harness.flushedBatches.count, 1)
        XCTAssertEqual(harness.session.compositionMode, .hangul)
        XCTAssertEqual(harness.session.preeditText, "")
    }

    func testPanelStateMovePageWrapsForwardAndBackward() {
        let candidates = (0..<25).map { index in
            HanjaCandidate(
                reading: "한",
                value: "漢\(index)",
                comment: "",
                source: .system,
                usageCount: 0,
                frequency: 0,
                baseRank: index
            )
        }
        var state = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: "한"),
            anchorRange: NSRange(location: 0, length: 1),
            candidates: candidates
        )
        XCTAssertEqual(state.pageCount, 3)

        state.movePage(by: 1)
        XCTAssertEqual(state.page, 1)
        state.movePage(by: 1)
        XCTAssertEqual(state.page, 2)
        state.movePage(by: 1)
        XCTAssertEqual(state.page, 0, "Tab on last page must wrap to first page")

        state.movePage(by: -1)
        XCTAssertEqual(state.page, 2, "Shift+Tab on first page must wrap to last page")
    }

    func testClearingRealtimeCandidateStatePreservesClauseAndPendingUsage() {
        let harness = makeHarness(rawText: "한국")
        harness.session.applyRealtimeCandidateSelection(harness.selectedCandidate)
        let panelState = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: "한국"),
            anchorRange: NSRange(location: 0, length: 2),
            candidates: harness.candidates
        )
        harness.session.setRealtimeCandidateState(panelState)
        XCTAssertTrue(harness.session.isShowingRealtimeCandidates)

        harness.session.clearRealtimeCandidateState()

        XCTAssertFalse(harness.session.isShowingRealtimeCandidates)
        XCTAssertEqual(harness.session.compositionMode, .realtimeHanja)
        XCTAssertEqual(harness.session.realtimeClauseState.rawClauseText, "한국")
        XCTAssertEqual(harness.session.realtimeClauseState.pendingUsageEvents.map(\.value), ["漢國"])
    }

    func testSpaceAppendKeepsClauseAndPendingUsage() {
        let harness = makeHarness(rawText: "한국")
        harness.session.applyRealtimeCandidateSelection(harness.selectedCandidate)
        let pendingBefore = harness.session.realtimeClauseState.pendingUsageEvents

        harness.session.appendSpaceToRealtimeClause()

        XCTAssertEqual(harness.session.realtimeClauseState.rawClauseText, "한국 ")
        XCTAssertEqual(harness.session.realtimeClauseState.pendingUsageEvents, pendingBefore)
        XCTAssertEqual(harness.session.compositionMode, .realtimeHanja)
    }

    func testBackspaceCascadeShrinksPreeditBeforeRawClause() {
        let session = InputSession()
        session.appendCommittedTextToRealtimeClause("한")
        XCTAssertTrue(session.process("r"))
        session.syncRealtimeTailPreedit()
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "한")
        XCTAssertEqual(unicodeScalarValues(of: session.realtimeClauseState.tailPreedit), [0x3131])

        XCTAssertTrue(session.backspace())
        XCTAssertEqual(session.preeditText, "")

        session.syncRealtimeTailPreedit()
        XCTAssertEqual(session.realtimeClauseState.tailPreedit, "")
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "한")

        XCTAssertTrue(session.deleteLastRealtimeRawCharacter())
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "")
        XCTAssertFalse(session.hasRealtimeClause)
        XCTAssertEqual(session.compositionMode, .hangul)
    }

    // MARK: - Helpers

    private final class FlushSink {
        var batches: [[PendingHanjaUsageEvent]] = []
    }

    private struct Harness {
        let client: FakeIMKTextInput
        let session: InputSession
        let engine: InputCompositionEngine
        let defaultCandidate: HanjaCandidate
        let selectedCandidate: HanjaCandidate
        let candidates: [HanjaCandidate]
        let flushSink: FlushSink

        var flushedBatches: [[PendingHanjaUsageEvent]] { flushSink.batches }
    }

    private func makeHarness(rawText: String) -> Harness {
        let client = FakeIMKTextInput()
        let session = InputSession()
        let defaultCandidate = HanjaCandidate(
            reading: rawText,
            value: "韓國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )
        let selectedCandidate = HanjaCandidate(
            reading: rawText,
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 1
        )
        let candidates = [defaultCandidate, selectedCandidate]
        let lookup: (String) -> [HanjaCandidate] = { key in
            key == rawText ? candidates : []
        }
        let utf16Length = (rawText as NSString).length
        let tokens = [Token(form: rawText, tag: .nnp, position: 0, length: utf16Length)]
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: rawText,
            candidateLookup: lookup
        )
        session.appendCommittedTextToRealtimeClause(rawText)
        session.updateRealtimeAnalysis(segments: segments)

        let flushSink = FlushSink()
        let engine = makeEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: { _ in segments },
            flushRealtimeUsageEvents: { flushSink.batches.append($0) }
        )

        return Harness(
            client: client,
            session: session,
            engine: engine,
            defaultCandidate: defaultCandidate,
            selectedCandidate: selectedCandidate,
            candidates: candidates,
            flushSink: flushSink
        )
    }

    private func makeEngine(
        client: FakeIMKTextInput,
        session: InputSession,
        analyzeRealtimeClause: @escaping (String) -> [HanjaSegment] = { _ in [] },
        analyzeManualClause: @escaping (String, [Int]) -> [HanjaSegment] = { _, _ in [] },
        flushRealtimeUsageEvents: @escaping ([PendingHanjaUsageEvent]) -> Void = { _ in }
    ) -> InputCompositionEngine {
        InputCompositionEngine(
            client: client,
            session: session,
            analyzeRealtimeClause: analyzeRealtimeClause,
            analyzeManualClause: analyzeManualClause,
            flushRealtimeUsageEvents: flushRealtimeUsageEvents,
            updateComposition: {},
            debugLog: { _ in }
        )
    }
}

private func unicodeScalarValues(of text: String) -> [UInt32] {
    text.unicodeScalars.map(\.value)
}
