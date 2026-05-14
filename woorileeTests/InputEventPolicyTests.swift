// Tests for key-event normalization and classification.
//     Copyright (C) 2026 Seungjin Lee.

import AppKit
import XCTest
@testable import woorilee

final class InputEventPolicyTests: XCTestCase {
    func testPrintableASCIICharacterUsesEventCharacters() throws {
        let event = try makeKeyEvent(
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifierFlags: [],
            keyCode: 0
        )

        XCTAssertEqual(InputEventPolicy.normalizedASCIICharacter(for: event), "a")
    }

    func testShiftedTwoBeolsikKeyPromotesMappedLetter() throws {
        let event = try makeKeyEvent(
            characters: "Q",
            charactersIgnoringModifiers: "q",
            modifierFlags: .shift,
            keyCode: 12
        )

        XCTAssertEqual(InputEventPolicy.normalizedASCIICharacter(for: event), "Q")
    }

    func testShiftedUnmappedLetterStaysLowercase() throws {
        let event = try makeKeyEvent(
            characters: "S",
            charactersIgnoringModifiers: "s",
            modifierFlags: .shift,
            keyCode: 1
        )

        XCTAssertEqual(InputEventPolicy.normalizedASCIICharacter(for: event), "s")
    }

    func testNavigationCommandDetectionMatchesSelectorPolicy() {
        XCTAssertTrue(InputEventPolicy.isNavigationCommand(NSSelectorFromString("moveLeft:")))
        XCTAssertTrue(InputEventPolicy.isNavigationCommand(NSSelectorFromString("pageDown:")))
        XCTAssertFalse(InputEventPolicy.isNavigationCommand(NSSelectorFromString("insertText:")))
    }

    func testManualHanjaTriggerMatchesOptionReturnKeyCode() {
        XCTAssertTrue(
            InputEventPolicy.isManualHanjaTrigger(
                keyCode: InputEventPolicy.KeyCode.returnKey,
                modifiers: .option
            )
        )
    }

    func testManualHanjaTriggerRejectsOptionShiftReturnKeyCode() {
        XCTAssertFalse(
            InputEventPolicy.isManualHanjaTrigger(
                keyCode: InputEventPolicy.KeyCode.returnKey,
                modifiers: [.option, .shift]
            )
        )
    }

    func testManualHanjaTriggerMatchesOptionOnlyModifiers() {
        XCTAssertTrue(InputEventPolicy.isManualHanjaTrigger(modifiers: .option))
        XCTAssertFalse(InputEventPolicy.isManualHanjaTrigger(modifiers: [.option, .command]))
    }

    func testRealtimeHanjaToggleShortcutMatchesControlA() {
        XCTAssertTrue(
            InputEventPolicy.isRealtimeHanjaToggleShortcut(
                modifiers: .control,
                characters: "a"
            )
        )
    }

    func testRealtimeHanjaToggleShortcutIsCaseInsensitive() {
        XCTAssertTrue(
            InputEventPolicy.isRealtimeHanjaToggleShortcut(
                modifiers: .control,
                characters: "A"
            )
        )
    }

    func testRealtimeHanjaToggleShortcutRejectsExtraModifiers() {
        XCTAssertFalse(
            InputEventPolicy.isRealtimeHanjaToggleShortcut(
                modifiers: [.control, .shift],
                characters: "a"
            )
        )
        XCTAssertFalse(
            InputEventPolicy.isRealtimeHanjaToggleShortcut(
                modifiers: [.control, .command],
                characters: "a"
            )
        )
    }

    func testRealtimeHanjaToggleShortcutRejectsUnrelatedKey() {
        XCTAssertFalse(
            InputEventPolicy.isRealtimeHanjaToggleShortcut(
                modifiers: .control,
                characters: "s"
            )
        )
    }

    func testNewlineCommandDetectionMatchesInsertNewlineSelectors() {
        XCTAssertTrue(InputEventPolicy.isNewlineCommand(NSSelectorFromString("insertNewline:")))
        XCTAssertTrue(InputEventPolicy.isNewlineCommand(NSSelectorFromString("insertLineBreak:")))
        XCTAssertTrue(InputEventPolicy.isNewlineCommand(NSSelectorFromString("insertParagraphSeparator:")))
        XCTAssertTrue(InputEventPolicy.isNewlineCommand(NSSelectorFromString("insertNewlineIgnoringFieldEditor:")))
        XCTAssertFalse(InputEventPolicy.isNewlineCommand(NSSelectorFromString("moveLeft:")))
    }

    func testRealtimeAutoCommitTriggersForSentenceBoundaryCharacters() {
        for trigger in [".", "?", "!", ";", "\n", "\r"] as [Character] {
            XCTAssertTrue(
                RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting(trigger),
                "expected '\(trigger)' to trigger auto-commit"
            )
        }
    }

    func testRealtimeAutoCommitTriggersForASCIILetters() {
        for trigger in ["a", "Z", "m"] as [Character] {
            XCTAssertTrue(
                RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting(trigger),
                "expected '\(trigger)' to trigger auto-commit"
            )
        }
    }

    func testRealtimeAutoCommitSkipsClauseFriendlyCharacters() {
        for keepInClause in ["0", "5", "9", ",", ":", " ", "한", "ㄱ", "漢"] as [Character] {
            XCTAssertFalse(
                RealtimeClauseAutoCommitPolicy.shouldCommitBeforeInserting(keepInClause),
                "expected '\(keepInClause)' to stay inside the realtime clause"
            )
        }
    }

    private func makeKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw XCTestError(.failureWhileWaiting)
        }

        return event
    }
}
