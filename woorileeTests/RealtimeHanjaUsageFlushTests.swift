// Tests for pending usage events flush and drop.
//     Copyright (C) 2026 Seungjin Lee.

// Locks the pendingUsageEvents flush/drop table from
// hanja-implementation-plan-plus.md section 5.3.
//
//   Return (clause commit) → flush via commitRealtimeComposition
//   Escape (clause cancel) → drop via clearRealtimeClauseState
//   Last-segment auto-advance commit → flush (covered by commit tests)
//   InputSession.reset() → drop (cache eviction path)
//   Hangul fallback selection → queues Hangul-valued pending event

import AppKit
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class RealtimeHanjaUsageFlushTests: XCTestCase {
    func testApplyCandidateSelectionQueuesPendingUsageOnce() {
        let setup = makeStateAndCandidates(rawText: "한국")
        var state = setup.state

        XCTAssertTrue(state.applyCandidateSelection(setup.alternate))

        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["漢國"])
        XCTAssertEqual(state.pendingUsageEvents.map(\.lookupKey), ["한국"])

        XCTAssertTrue(state.applyCandidateSelection(setup.preferred))
        XCTAssertEqual(
            state.pendingUsageEvents.map(\.value),
            ["韓國"],
            "Re-selecting on the same segment must replace, not duplicate"
        )
    }

    func testHangulFallbackQueuesHangulValuedPendingUsage() {
        let setup = makeStateAndCandidates(rawText: "한국")
        var state = setup.state

        XCTAssertTrue(state.applyHangulFallbackForSelectedSegment())

        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["한국"])
        XCTAssertEqual(state.pendingUsageEvents.map(\.lookupKey), ["한국"])
    }

    func testDrainPendingUsageEmptiesSessionBuffer() {
        let session = InputSession()
        session.appendCommittedTextToRealtimeClause("한국")
        session.updateRealtimeAnalysis(segments: segments(for: "한국"))
        let candidate = HanjaCandidate(
            reading: "한국",
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )
        XCTAssertTrue(session.applyRealtimeCandidateSelection(candidate))

        let drained = session.drainPendingRealtimeUsageEvents()
        XCTAssertEqual(drained.map(\.value), ["漢國"])
        XCTAssertTrue(session.realtimeClauseState.pendingUsageEvents.isEmpty)

        let drainedTwice = session.drainPendingRealtimeUsageEvents()
        XCTAssertTrue(drainedTwice.isEmpty)
    }

    func testClearRealtimeClauseStateDropsPendingUsageWithoutFlushing() {
        let session = InputSession()
        session.appendCommittedTextToRealtimeClause("한국")
        session.updateRealtimeAnalysis(segments: segments(for: "한국"))
        let candidate = HanjaCandidate(
            reading: "한국",
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )
        XCTAssertTrue(session.applyRealtimeCandidateSelection(candidate))
        XCTAssertEqual(session.realtimeClauseState.pendingUsageEvents.count, 1)

        session.clearRealtimeClauseState()

        XCTAssertTrue(session.realtimeClauseState.pendingUsageEvents.isEmpty)
        XCTAssertEqual(session.compositionMode, .hangul)
        XCTAssertEqual(session.realtimeClauseState, RealtimeClauseState())
    }

    func testSessionResetDropsPendingUsageWithoutFlushing() {
        let session = InputSession()
        session.appendCommittedTextToRealtimeClause("한국")
        session.updateRealtimeAnalysis(segments: segments(for: "한국"))
        let candidate = HanjaCandidate(
            reading: "한국",
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )
        XCTAssertTrue(session.applyRealtimeCandidateSelection(candidate))
        XCTAssertFalse(session.realtimeClauseState.pendingUsageEvents.isEmpty)

        session.reset()

        XCTAssertEqual(session.realtimeClauseState, RealtimeClauseState())
        XCTAssertEqual(session.compositionMode, .hangul)
    }

    func testRealtimeAnalysisDoesNotInvalidateLockedPendingUsage() {
        let setup = makeStateAndCandidates(rawText: "한국")
        var state = setup.state
        XCTAssertTrue(state.applyCandidateSelection(setup.alternate))
        XCTAssertEqual(state.pendingUsageEvents.count, 1)

        let resegments = KiwiAnalysisService.makeRealtimeSegments(
            from: [Token(form: "한국", tag: .nnp, position: 0, length: 2)],
            in: "한국",
            candidateLookup: { key in
                key == "한국" ? [setup.preferred, setup.alternate] : []
            }
        )
        state.updateAnalysis(segments: resegments)

        XCTAssertEqual(state.pendingUsageEvents.map(\.value), ["漢國"])
        XCTAssertEqual(state.previewClauseText, "漢國")
    }

    func testRealtimeAnalysisDropsPendingUsageWhenSegmentDisappears() {
        let setup = makeStateAndCandidates(rawText: "한국")
        var state = setup.state
        XCTAssertTrue(state.applyCandidateSelection(setup.alternate))
        XCTAssertEqual(state.pendingUsageEvents.count, 1)

        state.updateAnalysis(segments: [])

        XCTAssertTrue(
            state.pendingUsageEvents.isEmpty,
            "Pending event must drop when its segment vanishes from analysis"
        )
    }

    // MARK: - Helpers

    private struct CandidateSetup {
        let state: RealtimeClauseState
        let preferred: HanjaCandidate
        let alternate: HanjaCandidate
    }

    private func makeStateAndCandidates(rawText: String) -> CandidateSetup {
        let preferred = HanjaCandidate(
            reading: rawText,
            value: "韓國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )
        let alternate = HanjaCandidate(
            reading: rawText,
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 1
        )
        var state = RealtimeClauseState()
        state.rawClauseText = rawText
        state.updateAnalysis(segments: segments(for: rawText, candidates: [preferred, alternate]))
        return CandidateSetup(state: state, preferred: preferred, alternate: alternate)
    }

    private func segments(
        for rawText: String,
        candidates: [HanjaCandidate]? = nil
    ) -> [HanjaSegment] {
        let utf16Length = (rawText as NSString).length
        let tokens = [Token(form: rawText, tag: .nnp, position: 0, length: utf16Length)]
        let resolvedCandidates = candidates ?? [
            HanjaCandidate(
                reading: rawText,
                value: "韓國",
                comment: "",
                source: .system,
                usageCount: 0,
                frequency: 0,
                baseRank: 0
            )
        ]
        return KiwiAnalysisService.makeRealtimeSegments(
            from: tokens,
            in: rawText,
            candidateLookup: { key in key == rawText ? resolvedCandidates : [] }
        )
    }
}
