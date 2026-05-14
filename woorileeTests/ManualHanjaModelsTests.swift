import Foundation
import XCTest
@testable import woorilee

final class ManualHanjaModelsTests: XCTestCase {
    func testDocumentTargetReadsTokenImmediatelyLeftOfCaret() {
        let target = manualHanjaTarget(
            fromLeftContext: "대한민국",
            actualRange: NSRange(location: 0, length: 4),
            caretLocation: 4
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 4, length: 0))
    }

    func testDocumentTargetReadsTokenWhenActualRangeStartsAfterDocumentStart() {
        let target = manualHanjaTarget(
            fromLeftContext: "대한민국",
            actualRange: NSRange(location: 7, length: 4),
            caretLocation: 11
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 7, length: 4))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 11, length: 0))
    }

    func testDocumentTargetUsesTextAfterLastWhitespace() {
        let target = manualHanjaTarget(
            fromLeftContext: "abc 대한민국",
            actualRange: NSRange(location: 20, length: 8),
            caretLocation: 28
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 24, length: 4))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 28, length: 0))
    }

    func testCompositionTargetCombinesCommittedPrefixAndMarkedText() {
        let target = manualHanjaTarget(
            fromCommittedLeftText: "안",
            committedRange: NSRange(location: 0, length: 1),
            markedText: "녕",
            markedRange: NSRange(location: 1, length: 1)
        )

        XCTAssertEqual(target?.sourceText, "안녕")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 2, length: 0))
    }

    func testCompositionTargetStopsAtWhitespaceBeforeMarkedText() {
        let target = manualHanjaTarget(
            fromCommittedLeftText: "가 ",
            committedRange: NSRange(location: 0, length: 2),
            markedText: "나",
            markedRange: NSRange(location: 2, length: 1)
        )

        XCTAssertEqual(target?.sourceText, "나")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 2, length: 1))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 3, length: 0))
    }

    func testDocumentTargetKeepsWholeTokenForExactManualLookup() {
        let target = manualHanjaTarget(
            fromLeftContext: "한국",
            actualRange: NSRange(location: 10, length: 2),
            caretLocation: 12
        )

        XCTAssertEqual(target?.sourceText, "한국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 10, length: 2))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 12, length: 0))
    }

    func testSelectedTextTargetUsesEntireSelectedRange() {
        let target = manualHanjaTarget(
            fromSelectedText: "한국 사람",
            actualRange: NSRange(location: 5, length: 5)
        )

        XCTAssertEqual(target?.sourceText, "한국 사람")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 5, length: 5))
        XCTAssertEqual(target?.anchorRange, NSRange(location: 10, length: 0))
    }

    func testSelectedTextTargetRejectsWhitespaceOnlySelection() {
        let target = manualHanjaTarget(
            fromSelectedText: "  ",
            actualRange: NSRange(location: 5, length: 2)
        )

        XCTAssertNil(target)
    }

    func testDocumentTargetStopsAtOpenParenthesis() {
        let target = manualHanjaTarget(
            fromLeftContext: "(대한민국",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 1, length: 4))
    }

    func testDocumentTargetStopsAtCloseParenthesis() {
        let target = manualHanjaTarget(
            fromLeftContext: "대한)민국",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertEqual(target?.sourceText, "민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 3, length: 2))
    }

    func testDocumentTargetStopsAtDoubleQuote() {
        let target = manualHanjaTarget(
            fromLeftContext: "\"대한민국",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 1, length: 4))
    }

    func testDocumentTargetStopsAtCurlyQuote() {
        let target = manualHanjaTarget(
            fromLeftContext: "\u{201C}대한민국",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 1, length: 4))
    }

    func testDocumentTargetStopsAtCJKBracket() {
        let target = manualHanjaTarget(
            fromLeftContext: "「대한민국",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertEqual(target?.sourceText, "대한민국")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 1, length: 4))
    }

    func testDocumentTargetReturnsNilWhenCaretIsRightAfterDelimiter() {
        let target = manualHanjaTarget(
            fromLeftContext: "대한민국)",
            actualRange: NSRange(location: 0, length: 5),
            caretLocation: 5
        )

        XCTAssertNil(target)
    }

    func testCompositionTargetStopsAtParenthesisBeforeMarkedText() {
        let target = manualHanjaTarget(
            fromCommittedLeftText: "(가",
            committedRange: NSRange(location: 0, length: 2),
            markedText: "나",
            markedRange: NSRange(location: 2, length: 1)
        )

        XCTAssertEqual(target?.sourceText, "가나")
        XCTAssertEqual(target?.replacementRange, NSRange(location: 1, length: 2))
    }

    func testCandidatePanelStatePaginatesNineCandidatesPerPage() {
        let state = HanjaCandidatePanelState(
            mode: .manual(sourceText: Self.target.sourceText, replacementRange: Self.target.replacementRange),
            anchorRange: Self.target.anchorRange,
            candidates: Self.candidates(count: 12)
        )

        XCTAssertTrue(state.mode.allowsNumberedSelection)
        XCTAssertEqual(state.pageCount, 2)
        XCTAssertEqual(state.visibleCandidateRange, 0..<9)
        XCTAssertEqual(state.pageNumberLabel(forAbsoluteIndex: 0), "1")
        XCTAssertEqual(state.pageNumberLabel(forAbsoluteIndex: 8), "9")
        XCTAssertEqual(state.candidateForPageNumberIndex(8)?.value, "候補8")
        XCTAssertNil(state.candidateForPageNumberIndex(9))
    }

    func testCandidatePanelStateMovesPageAndSelectsVisibleNumber() {
        var state = HanjaCandidatePanelState(
            mode: .manual(sourceText: Self.target.sourceText, replacementRange: Self.target.replacementRange),
            anchorRange: Self.target.anchorRange,
            candidates: Self.candidates(count: 12)
        )

        state.movePage(by: 1)

        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.highlightedIndex, 9)
        XCTAssertEqual(state.visibleCandidateRange, 9..<12)
        XCTAssertEqual(state.candidateForPageNumberIndex(2)?.value, "候補11")
        XCTAssertNil(state.candidateForPageNumberIndex(3))
    }

    func testCandidatePanelStateMovesHighlightAcrossPagesWithWrap() {
        var state = HanjaCandidatePanelState(
            mode: .manual(sourceText: Self.target.sourceText, replacementRange: Self.target.replacementRange),
            anchorRange: Self.target.anchorRange,
            candidates: Self.candidates(count: 12)
        )

        state.moveHighlight(by: -1)
        XCTAssertTrue(state.highlightedIsHangul)

        state.moveHighlight(by: -1)
        XCTAssertEqual(state.highlightedIndex, 11)
        XCTAssertEqual(state.page, 1)
        XCTAssertFalse(state.highlightedIsHangul)

        state.moveHighlight(by: 1)
        XCTAssertTrue(state.highlightedIsHangul)

        state.moveHighlight(by: 1)
        XCTAssertEqual(state.highlightedIndex, 0)
        XCTAssertEqual(state.page, 0)
        XCTAssertFalse(state.highlightedIsHangul)
    }

    func testHangulHighlightFallsOffOnArrowMovement() {
        var state = HanjaCandidatePanelState(
            mode: .manual(sourceText: Self.target.sourceText, replacementRange: Self.target.replacementRange),
            anchorRange: Self.target.anchorRange,
            candidates: Self.candidates(count: 12),
            highlightedIsHangul: true
        )

        XCTAssertTrue(state.highlightedIsHangul)

        state.moveHighlight(by: 1)

        XCTAssertFalse(state.highlightedIsHangul)
        XCTAssertEqual(state.highlightedIndex, 0)
        XCTAssertEqual(state.page, 0)
    }

    func testHangulHighlightFallsOffOnPageChange() {
        var state = HanjaCandidatePanelState(
            mode: .manual(sourceText: Self.target.sourceText, replacementRange: Self.target.replacementRange),
            anchorRange: Self.target.anchorRange,
            candidates: Self.candidates(count: 12),
            highlightedIsHangul: true
        )

        state.movePage(by: 1)

        XCTAssertFalse(state.highlightedIsHangul)
        XCTAssertEqual(state.page, 1)
    }

    private static let target = ManualHanjaTarget(
        sourceText: "후보",
        replacementRange: NSRange(location: 0, length: 2),
        anchorRange: NSRange(location: 2, length: 0)
    )

    private static func candidates(count: Int) -> [HanjaCandidate] {
        (0..<count).map { index in
            HanjaCandidate(
                reading: "후보",
                value: "候補\(index)",
                comment: "",
                source: .system,
                usageCount: 0,
                frequency: 0,
                baseRank: index
            )
        }
    }
}
