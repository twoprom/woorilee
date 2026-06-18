// Tests for Hanja panel anchor probing.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import XCTest
@testable import woorilee

final class ManualHanjaPanelAnchorResolverTests: XCTestCase {
    func testCandidateAnchorRangesPreferCaretAnchorThenTextRanges() {
        let target = ManualHanjaTarget(
            sourceText: "한국",
            replacementRange: NSRange(location: 10, length: 2),
            anchorRange: NSRange(location: 12, length: 0)
        )
        let state = HanjaCandidatePanelState(
            mode: .manual(sourceText: target.sourceText, replacementRange: target.replacementRange),
            anchorRange: target.anchorRange,
            candidates: []
        )

        let ranges = ManualHanjaPanelAnchorResolver.anchorCandidateRanges(
            for: .candidates(state),
            markedRange: NSRange(location: 10, length: 2),
            selectedRange: NSRange(location: 12, length: 0)
        )

        XCTAssertEqual(
            ranges,
            [
                NSRange(location: 12, length: 0),
                NSRange(location: 10, length: 2),
            ]
        )
    }

    func testRealtimeCandidateAnchorRangesDoNotUseManualReplacementRange() {
        let state = HanjaCandidatePanelState(
            mode: .realtime(segmentIndex: 0, segmentSurface: "한국"),
            anchorRange: NSRange(location: 12, length: 2),
            candidates: []
        )

        let ranges = ManualHanjaPanelAnchorResolver.anchorCandidateRanges(
            for: .candidates(state),
            markedRange: NSRange(location: 10, length: 4),
            selectedRange: NSRange(location: 14, length: 0)
        )

        XCTAssertEqual(
            ranges,
            [
                NSRange(location: 12, length: 2),
                NSRange(location: 10, length: 4),
                NSRange(location: 14, length: 0),
            ]
        )
    }

    func testNoticeAnchorRangesUseNoticeAnchorBeforeSelection() {
        let notice = ManualHanjaNoticeState(
            message: "변환할 텍스트가 없습니다.",
            detail: nil,
            anchorRange: NSRange(location: 3, length: 0)
        )

        let ranges = ManualHanjaPanelAnchorResolver.anchorCandidateRanges(
            for: .notice(notice),
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 5, length: 0)
        )

        XCTAssertEqual(
            ranges,
            [
                NSRange(location: 3, length: 0),
                NSRange(location: 5, length: 0),
            ]
        )
    }

    func testAnchorRangesFilterNotFoundAndDeduplicate() {
        let notice = ManualHanjaNoticeState(
            message: "변환할 텍스트가 없습니다.",
            detail: nil,
            anchorRange: NSRange(location: 3, length: 0)
        )

        let ranges = ManualHanjaPanelAnchorResolver.anchorCandidateRanges(
            for: .notice(notice),
            markedRange: NSRange(location: NSNotFound, length: 0),
            selectedRange: NSRange(location: 3, length: 0)
        )

        XCTAssertEqual(ranges, [NSRange(location: 3, length: 0)])
    }

    @MainActor
    func testAugmentsTinyFirstRectHeightFromLineHeightRectangle() {
        let client = FakeIMKTextInput()
        client.lineHeightRectHandler = { index in
            index == 5 ? NSRect(x: 0, y: 500, width: 0, height: 18) : .zero
        }

        let result = ManualHanjaPanelAnchorResolver.augmentedLineHeight(
            of: NSRect(x: 100, y: 500, width: 0, height: 1),
            characterIndex: 5,
            client: client
        )

        // Keeps firstRect's x and line bottom, adopts the real line height.
        XCTAssertEqual(result, NSRect(x: 100, y: 500, width: 0, height: 18))
    }

    @MainActor
    func testKeepsFirstRectWhenHeightAlreadyHealthy() {
        let client = FakeIMKTextInput()
        client.lineHeightRectHandler = { _ in NSRect(x: 0, y: 0, width: 0, height: 99) }
        let healthy = NSRect(x: 100, y: 500, width: 0, height: 18)

        let result = ManualHanjaPanelAnchorResolver.augmentedLineHeight(
            of: healthy,
            characterIndex: 5,
            client: client
        )

        XCTAssertEqual(result, healthy)
    }

    @MainActor
    func testReverseSearchWalksBackToFirstValidLineHeightRect() {
        let client = FakeIMKTextInput()
        // Caret index 12 yields an empty rect; index 11 yields a valid line rect.
        client.lineHeightRectHandler = { index in
            index == 11 ? NSRect(x: 80, y: 400, width: 0, height: 18) : .zero
        }
        let screenFrames = [NSRect(x: 0, y: 0, width: 1440, height: 900)]

        let result = ManualHanjaPanelAnchorResolver.reverseLineHeightRect(
            caretIndex: 12,
            client: client,
            screenFrames: screenFrames
        )

        XCTAssertEqual(result, NSRect(x: 80, y: 400, width: 0, height: 18))
    }

    @MainActor
    func testReverseSearchGivesUpAfterStepLimit() {
        let client = FakeIMKTextInput()
        // Only index 0 is valid, but the caret is far beyond the step limit.
        client.lineHeightRectHandler = { index in
            index == 0 ? NSRect(x: 80, y: 400, width: 0, height: 18) : .zero
        }
        let screenFrames = [NSRect(x: 0, y: 0, width: 1440, height: 900)]

        let result = ManualHanjaPanelAnchorResolver.reverseLineHeightRect(
            caretIndex: 100,
            client: client,
            screenFrames: screenFrames
        )

        XCTAssertNil(result)
    }

    func testValidAnchorRectRequiresFiniteVisibleRect() {
        let screenFrame = NSRect(x: 0, y: 0, width: 200, height: 200)

        XCTAssertTrue(
            ManualHanjaPanelAnchorResolver.isValidAnchorRect(
                NSRect(x: 40, y: 40, width: 0, height: 18),
                screenFrames: [screenFrame]
            )
        )
        XCTAssertFalse(
            ManualHanjaPanelAnchorResolver.isValidAnchorRect(
                NSRect(x: 40, y: 40, width: 0, height: 0.5),
                screenFrames: [screenFrame]
            )
        )
        XCTAssertFalse(
            ManualHanjaPanelAnchorResolver.isValidAnchorRect(
                NSRect(x: 240, y: 240, width: 0, height: 18),
                screenFrames: [screenFrame]
            )
        )
    }
}
