//
//  InputEventPolicy.swift
//  woorilee
//

import Cocoa

enum InputEventPolicy {
    enum KeyCode {
        static let backspace: UInt16 = 51
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let tab: UInt16 = 48
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    static let realtimeHanjaToggleKeyEquivalent = "a"
    static let realtimeHanjaToggleModifierMask: NSEvent.ModifierFlags = .control

    private static let printableQWERTYKeyMap: [UInt16: Character] = [
        0: "a",
        1: "s",
        2: "d",
        3: "f",
        4: "h",
        5: "g",
        6: "z",
        7: "x",
        8: "c",
        9: "v",
        11: "b",
        12: "q",
        13: "w",
        14: "e",
        15: "r",
        16: "y",
        17: "t",
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        22: "6",
        23: "5",
        24: "=",
        25: "9",
        26: "7",
        27: "-",
        28: "8",
        29: "0",
        30: "]",
        31: "o",
        32: "u",
        33: "[",
        34: "i",
        35: "p",
        37: "l",
        38: "j",
        39: "'",
        40: "k",
        41: ";",
        42: "\\",
        43: ",",
        44: "/",
        45: "n",
        46: "m",
        47: ".",
        50: "`",
    ]

    private static let dubeolsikShiftedLetters: Set<Character> = ["q", "w", "e", "r", "t", "o", "p"]

    private static let navigationCommandPrefixes = [
        "moveLeft",
        "moveRight",
        "moveUp",
        "moveDown",
        "moveWordLeft",
        "moveWordRight",
        "moveBackward",
        "moveForward",
        "moveToBeginningOf",
        "moveToEndOf",
    ]

    private static let navigationCommands: Set<String> = [
        "pageUp:",
        "pageDown:",
        "scrollPageUp:",
        "scrollPageDown:",
    ]

    private static let newlineCommands: Set<String> = [
        "insertNewline:",
        "insertParagraphSeparator:",
        "insertNewlineIgnoringFieldEditor:",
        "insertLineBreak:",
    ]

    static func shouldPassThrough(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }

    static func normalizedASCIICharacter(for event: NSEvent) -> Character? {
        normalizedASCIICharacter(
            characters: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        )
    }

    static func normalizedASCIICharacter(
        characters: String?,
        keyCode: UInt16? = nil,
        modifiers: NSEvent.ModifierFlags? = nil
    ) -> Character? {
        let shifted = modifiers?.contains(.shift) ?? false

        if let characters,
           characters.count == 1,
           let character = characters.first,
           isPrintableASCII(character)
        {
            let normalizedCharacter: Character
            if character.isLetter {
                normalizedCharacter = Character(String(character).lowercased())
            } else {
                normalizedCharacter = character
            }

            let effectiveShift = modifiers != nil ? shifted : character.isUppercase
            return applyShift(to: normalizedCharacter, shifted: effectiveShift)
        }

        guard let keyCode, let baseCharacter = printableQWERTYKeyMap[keyCode] else {
            return nil
        }

        return applyShift(to: baseCharacter, shifted: shifted)
    }

    static func isNavigationCommand(_ selector: Selector) -> Bool {
        let command = NSStringFromSelector(selector)
        if navigationCommands.contains(command) {
            return true
        }

        return navigationCommandPrefixes.contains { command.hasPrefix($0) }
    }

    static func isManualHanjaTrigger(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == KeyCode.returnKey || keyCode == KeyCode.enter else {
            return false
        }

        return isManualHanjaTrigger(modifiers: modifiers)
    }

    static func isManualHanjaTrigger(
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let relevantModifiers = modifiers.intersection([.command, .control, .option, .shift])
        return relevantModifiers == [.option]
    }

    static func isNewlineCommand(_ selector: Selector) -> Bool {
        newlineCommands.contains(NSStringFromSelector(selector))
    }

    static func isRealtimeHanjaToggleShortcut(
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> Bool {
        let relevantModifiers = modifiers.intersection([.command, .control, .option, .shift])
        guard relevantModifiers == realtimeHanjaToggleModifierMask else {
            return false
        }

        guard let characters, !characters.isEmpty else {
            return false
        }

        return characters.lowercased() == realtimeHanjaToggleKeyEquivalent
    }

    static func currentSessionModifierFlags() -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
    }

    static func isPrintableASCII(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else {
            return false
        }

        return ascii >= 0x20 && ascii <= 0x7E
    }

    static func numericCandidateIndex(keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        case 23: return 4
        case 22: return 5
        case 26: return 6
        case 28: return 7
        case 25: return 8
        case 29: return 9
        default: return nil
        }
    }

    private static func applyShift(to character: Character, shifted: Bool) -> Character? {
        guard character.isASCII else {
            return nil
        }

        if character.isLetter {
            let lowercased = Character(String(character).lowercased())
            guard shifted else {
                return lowercased
            }

            if dubeolsikShiftedLetters.contains(lowercased) {
                return Character(String(lowercased).uppercased())
            }

            return lowercased
        }

        guard shifted else {
            return character
        }

        switch character {
        case "1": return "!"
        case "2": return "@"
        case "3": return "#"
        case "4": return "$"
        case "5": return "%"
        case "6": return "^"
        case "7": return "&"
        case "8": return "*"
        case "9": return "("
        case "0": return ")"
        case "-": return "_"
        case "=": return "+"
        case "[": return "{"
        case "]": return "}"
        case "\\": return "|"
        case ";": return ":"
        case "'": return "\""
        case ",": return "<"
        case ".": return ">"
        case "/": return "?"
        case "`": return "~"
        default: return character
        }
    }
}
