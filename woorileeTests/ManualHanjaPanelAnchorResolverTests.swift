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
