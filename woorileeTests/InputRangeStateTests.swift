import Foundation
import XCTest
@testable import woorilee

final class InputRangeStateTests: XCTestCase {
    func testBeginCompositionUsesSelectedRangeWhenPresent() {
        var state = InputRangeState()

        state.beginCompositionIfNeeded(with: NSRange(location: 4, length: 2))

        XCTAssertEqual(state.currentReplacementRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(state.rangeHandlingDescription, "initial-selection")
    }

    func testSyncMarkedTextRangeSwitchesToClientMarkedMode() {
        var state = InputRangeState()

        state.syncMarkedTextRange(clientRange: NSRange(location: 3, length: 1))

        XCTAssertEqual(state.markedTextRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(state.currentReplacementRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(state.rangeHandlingDescription, "client-marked")
    }

    func testImplicitReplacementRangeUsesNotFoundWhenClientMarkedRangeDisappears() {
        var state = InputRangeState()

        state.syncMarkedTextRange(clientRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(state.currentReplacementRange, NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(state.rangeHandlingDescription, "implicit")
    }

    func testDidInsertCommittedTextAdvancesCompositionStartRange() {
        var state = InputRangeState()

        state.didInsertCommittedText(length: 2, replacedRange: NSRange(location: 5, length: 1))

        XCTAssertEqual(state.currentReplacementRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(state.rangeHandlingDescription, "initial-selection")
    }

    func testClearMarkedTextConvertsMarkedRangeIntoInsertionPoint() {
        var state = InputRangeState()
        state.syncMarkedTextRange(clientRange: NSRange(location: 8, length: 2))

        state.clearMarkedText()

        XCTAssertNil(state.markedTextRange)
        XCTAssertEqual(state.currentReplacementRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(state.rangeHandlingDescription, "initial-selection")
    }

    func testFinishCompositionResetsRangeState() {
        var state = InputRangeState()
        state.beginCompositionIfNeeded(with: NSRange(location: 1, length: 0))

        state.finishComposition()

        XCTAssertEqual(state.currentReplacementRange, NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(state.rangeHandlingDescription, "none")
    }
}
