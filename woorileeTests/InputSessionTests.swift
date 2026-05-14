// Tests for per-client input session behavior.
//     Copyright (C) 2026 Seungjin Lee.

import AppKit
import Kiwi
import XCTest
@testable import woorilee

@MainActor
final class InputSessionTests: XCTestCase {
    func testSingleInitialPreeditUsesCompatibilityJamo() {
        let session = InputSession()

        XCTAssertTrue(session.process("r"))

        XCTAssertEqual(session.preeditText, "ㄱ")
        XCTAssertEqual(unicodeScalarValues(of: session.preeditText), [0x3131])
    }

    func testCompletedSyllablePreeditUsesPrecomposedHangul() {
        let session = InputSession()

        XCTAssertTrue(session.process("r"))
        XCTAssertTrue(session.process("k"))

        XCTAssertEqual(session.preeditText, "가")
        XCTAssertEqual(unicodeScalarValues(of: session.preeditText), [0xAC00])
    }

    func testFlushTextUsesPrecomposedHangul() {
        let session = InputSession()

        XCTAssertTrue(session.process("g"))
        XCTAssertTrue(session.process("k"))
        XCTAssertTrue(session.process("s"))

        let flushedText = session.flushText()

        XCTAssertEqual(flushedText, "한")
        XCTAssertEqual(unicodeScalarValues(of: flushedText), [0xD55C])
    }

    func testCommittedTextUsesPrecomposedHangulAndRemainingPreeditUsesCompatibilityJamo() {
        let session = InputSession()

        XCTAssertTrue(session.process("g"))
        XCTAssertTrue(session.process("k"))
        XCTAssertTrue(session.process("s"))
        XCTAssertTrue(session.process("r"))

        let committedText = session.committedText

        XCTAssertEqual(committedText, "한")
        XCTAssertEqual(unicodeScalarValues(of: committedText), [0xD55C])
        XCTAssertEqual(session.preeditText, "ㄱ")
        XCTAssertEqual(unicodeScalarValues(of: session.preeditText), [0x3131])
    }

    func testRealtimeClauseStartsWithCommittedText() {
        let session = InputSession()

        session.appendCommittedTextToRealtimeClause("한")

        XCTAssertEqual(session.compositionMode, .realtimeHanja)
        XCTAssertTrue(session.hasRealtimeClause)
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "한")
        XCTAssertEqual(session.realtimeClauseState.tailPreedit, "")
        XCTAssertEqual(session.realtimeDisplayText, "한")
        XCTAssertTrue(session.realtimeClauseState.segments.isEmpty)
        XCTAssertTrue(session.realtimeClauseState.pendingUsageEvents.isEmpty)
    }

    func testRealtimeClauseDisplayIncludesTailPreedit() {
        let session = InputSession()

        session.appendCommittedTextToRealtimeClause("한")
        XCTAssertTrue(session.process("r"))
        session.syncRealtimeTailPreedit()

        XCTAssertEqual(session.compositionMode, .realtimeHanja)
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "한")
        XCTAssertEqual(session.realtimeClauseState.tailPreedit, session.preeditText)
        XCTAssertEqual(unicodeScalarValues(of: session.realtimeClauseState.tailPreedit), [0x3131])
        XCTAssertEqual(session.realtimeDisplayText, "한" + session.preeditText)
        XCTAssertFalse(session.realtimeClauseState.tailPreedit.isEmpty)
    }

    func testRealtimeRawBackspaceRemovesLastCharacter() {
        let session = InputSession()

        session.appendRawTextToRealtimeClause("한국")

        XCTAssertTrue(session.deleteLastRealtimeRawCharacter())
        XCTAssertEqual(session.compositionMode, .realtimeHanja)
        XCTAssertEqual(session.realtimeClauseState.rawClauseText, "한")
        XCTAssertEqual(session.realtimeDisplayText, "한")
    }

    func testRealtimeRawBackspaceClearsModeWhenClauseBecomesEmpty() {
        let session = InputSession()

        session.appendRawTextToRealtimeClause("한")

        XCTAssertTrue(session.deleteLastRealtimeRawCharacter())
        XCTAssertEqual(session.compositionMode, .hangul)
        XCTAssertFalse(session.hasRealtimeClause)
        XCTAssertEqual(session.realtimeDisplayText, "")
    }

    func testResetClearsRealtimeClauseState() {
        let session = InputSession()

        session.appendRawTextToRealtimeClause("한국")
        session.reset()

        XCTAssertEqual(session.compositionMode, .hangul)
        XCTAssertFalse(session.hasRealtimeClause)
        XCTAssertEqual(session.realtimeClauseState, RealtimeClauseState())
    }

    func testClearRealtimeClauseStateRevertsCompositionModeToHangul() {
        let session = InputSession()
        session.appendRawTextToRealtimeClause("한국")
        XCTAssertEqual(session.compositionMode, .realtimeHanja)

        session.clearRealtimeClauseState()

        XCTAssertEqual(session.compositionMode, .hangul)
        XCTAssertEqual(session.realtimeClauseState, RealtimeClauseState())
        XCTAssertTrue(session.realtimeClauseState.pendingUsageEvents.isEmpty)
    }

    func testDrainPendingRealtimeUsageEventsIsIdempotent() {
        let session = InputSession()
        session.appendCommittedTextToRealtimeClause("한국")
        let segments = KiwiAnalysisService.makeRealtimeSegments(
            from: [Token(form: "한국", tag: .nnp, position: 0, length: 2)],
            in: "한국",
            candidateLookup: { key in
                key == "한국"
                    ? [
                        HanjaCandidate(
                            reading: key,
                            value: "韓國",
                            comment: "",
                            source: .system,
                            usageCount: 0,
                            frequency: 0,
                            baseRank: 0
                        )
                    ]
                    : []
            }
        )
        session.updateRealtimeAnalysis(segments: segments)
        let candidate = HanjaCandidate(
            reading: "한국",
            value: "漢國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 1
        )
        XCTAssertTrue(session.applyRealtimeCandidateSelection(candidate))

        let drained = session.drainPendingRealtimeUsageEvents()
        XCTAssertEqual(drained.map(\.value), ["漢國"])
        XCTAssertTrue(session.realtimeClauseState.pendingUsageEvents.isEmpty)
        XCTAssertTrue(session.drainPendingRealtimeUsageEvents().isEmpty)
    }

    func testManualHanjaTriggerCanBeConsumedOnce() {
        let session = InputSession()

        session.armManualHanjaTrigger(
            keyCode: InputEventPolicy.KeyCode.returnKey,
            modifiers: .option,
            uptime: 10
        )

        let consumedTrigger = session.consumeManualHanjaTriggerIfArmedForNewline(
            nowUptime: 10.25,
            maxAge: 1
        )

        XCTAssertEqual(consumedTrigger?.keyCode, InputEventPolicy.KeyCode.returnKey)
        XCTAssertEqual(consumedTrigger?.modifiers, .option)
        XCTAssertNil(session.pendingManualHanjaTrigger)
        XCTAssertNil(
            session.consumeManualHanjaTriggerIfArmedForNewline(
                nowUptime: 10.5,
                maxAge: 1
            )
        )
    }

    func testExpiredManualHanjaTriggerIsNotConsumed() {
        let session = InputSession()

        session.armManualHanjaTrigger(
            keyCode: InputEventPolicy.KeyCode.enter,
            modifiers: .option,
            uptime: 5
        )

        XCTAssertNil(
            session.consumeManualHanjaTriggerIfArmedForNewline(
                nowUptime: 6.5,
                maxAge: 1
            )
        )
        XCTAssertNil(session.pendingManualHanjaTrigger)
    }

    func testClearManualHanjaTriggerRemovesPendingState() {
        let session = InputSession()

        session.armManualHanjaTrigger(
            keyCode: InputEventPolicy.KeyCode.returnKey,
            modifiers: .option,
            uptime: 1
        )
        session.clearManualHanjaTrigger()

        XCTAssertNil(session.pendingManualHanjaTrigger)
    }

    func testManualHanjaNewlineSuppressionCoversCurrentEventBurst() {
        let session = InputSession()

        session.suppressNextManualHanjaNewline(uptime: 10)

        XCTAssertTrue(
            session.consumeManualHanjaNewlineSuppressionIfNeeded(
                nowUptime: 10.25,
                maxAge: 0.5
            )
        )
        XCTAssertTrue(
            session.consumeManualHanjaNewlineSuppressionIfNeeded(
                nowUptime: 10.3,
                maxAge: 0.5
            )
        )

        session.clearManualHanjaNewlineSuppression()

        XCTAssertFalse(
            session.consumeManualHanjaNewlineSuppressionIfNeeded(
                nowUptime: 10.35,
                maxAge: 0.5
            )
        )
    }

    func testExpiredManualHanjaNewlineSuppressionIsNotConsumed() {
        let session = InputSession()

        session.suppressNextManualHanjaNewline(uptime: 5)

        XCTAssertFalse(
            session.consumeManualHanjaNewlineSuppressionIfNeeded(
                nowUptime: 5.75,
                maxAge: 0.5
            )
        )
    }

    func testSetManualNoticeStateMarksPanelVisible() {
        let session = InputSession()
        let notice = ManualHanjaNoticeState(
            message: "한자 사전을 불러오는 중입니다.",
            detail: nil,
            anchorRange: NSRange(location: 3, length: 0)
        )

        session.setManualNoticeState(notice)

        XCTAssertTrue(session.isShowingManualPanel)
        XCTAssertTrue(session.isShowingManualNotice)
        XCTAssertFalse(session.isShowingManualCandidates)
        XCTAssertEqual(session.manualNoticeState, notice)
    }

    func testClearManualPanelStateClearsCandidateAndNotice() {
        let session = InputSession()
        let target = ManualHanjaTarget(
            sourceText: "대한민국",
            replacementRange: NSRange(location: 0, length: 4),
            anchorRange: NSRange(location: 4, length: 0)
        )
        let candidate = HanjaCandidate(
            reading: "대한민국",
            value: "大韓民國",
            comment: "",
            source: .system,
            usageCount: 0,
            frequency: 0,
            baseRank: 0
        )

        session.setManualCandidateState(
            HanjaCandidatePanelState(
                mode: .manual(sourceText: target.sourceText, replacementRange: target.replacementRange),
                anchorRange: target.anchorRange,
                candidates: [candidate]
            ),
            lookupKey: "대한민국"
        )
        session.setManualNoticeState(
            ManualHanjaNoticeState(
                message: "변환할 텍스트가 없습니다.",
                detail: nil,
                anchorRange: NSRange(location: 4, length: 0)
            )
        )

        session.clearManualPanelState()

        XCTAssertFalse(session.isShowingManualPanel)
        XCTAssertNil(session.manualCandidateState)
        XCTAssertNil(session.manualNoticeState)
        XCTAssertNil(session.pendingManualReplacementRange)
        XCTAssertNil(session.pendingManualLookupKey)
    }
}

private func unicodeScalarValues(of text: String) -> [UInt32] {
    text.unicodeScalars.map(\.value)
}
