// Value types for the manual Hanja panel target, notice, and content.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

struct ManualHanjaTarget: Equatable {
    let sourceText: String
    let replacementRange: NSRange
    let anchorRange: NSRange
}

struct ManualHanjaNoticeState: Equatable {
    let message: String
    let detail: String?
    let anchorRange: NSRange
}

enum ManualHanjaPanelContent: Equatable {
    case candidates(HanjaCandidatePanelState)
    case notice(ManualHanjaNoticeState)

    var anchorRange: NSRange {
        switch self {
        case .candidates(let state):
            return state.anchorRange
        case .notice(let state):
            return state.anchorRange
        }
    }
}

struct ManualHanjaLookupResult {
    let state: HanjaCandidatePanelState
    let lookupKey: String
}

func manualHanjaTarget(
    fromLeftContext leftContext: String,
    actualRange: NSRange,
    caretLocation: Int
) -> ManualHanjaTarget? {
    guard actualRange.location != NSNotFound,
          actualRange.length == inputUTF16Length(of: leftContext),
          actualRange.location + actualRange.length == caretLocation
    else {
        return nil
    }

    return manualHanjaTarget(
        committedText: leftContext,
        committedRange: actualRange,
        markedText: "",
        markedRange: nil,
        caretLocation: caretLocation
    )
}

func manualHanjaTarget(
    fromSelectedText selectedText: String,
    actualRange: NSRange
) -> ManualHanjaTarget? {
    let selectedLength = inputUTF16Length(of: selectedText)
    guard actualRange.location != NSNotFound,
          actualRange.length == selectedLength,
          selectedLength > 0,
          !selectedText.allSatisfy(\.isWhitespace)
    else {
        return nil
    }

    return ManualHanjaTarget(
        sourceText: selectedText,
        replacementRange: actualRange,
        anchorRange: NSRange(location: actualRange.location + actualRange.length, length: 0)
    )
}

func manualHanjaTarget(
    fromCommittedLeftText committedText: String,
    committedRange: NSRange,
    markedText: String,
    markedRange: NSRange
) -> ManualHanjaTarget? {
    let caretLocation = markedRange.location + markedRange.length
    guard !markedText.isEmpty,
          committedRange.location != NSNotFound,
          committedRange.length == inputUTF16Length(of: committedText),
          markedRange.location != NSNotFound,
          markedRange.length == inputUTF16Length(of: markedText),
          committedRange.location + committedRange.length == markedRange.location
    else {
        return nil
    }

    return manualHanjaTarget(
        committedText: committedText,
        committedRange: committedRange,
        markedText: markedText,
        markedRange: markedRange,
        caretLocation: caretLocation
    )
}

private func manualHanjaTarget(
    committedText: String,
    committedRange: NSRange,
    markedText: String,
    markedRange: NSRange?,
    caretLocation: Int
) -> ManualHanjaTarget? {
    let contextText = committedText + markedText
    guard !contextText.isEmpty,
          let tokenRange = manualHanjaTrailingTokenRange(in: contextText)
    else {
        return nil
    }

    let startOffset = inputUTF16Length(of: String(contextText[..<tokenRange.lowerBound]))
    let endOffset = inputUTF16Length(of: String(contextText[..<tokenRange.upperBound]))

    guard let replacementLocation = manualHanjaDocumentOffset(
        forContextUTF16Offset: startOffset,
        committedRange: committedRange,
        markedRange: markedRange
    ),
    let replacementEnd = manualHanjaDocumentOffset(
        forContextUTF16Offset: endOffset,
        committedRange: committedRange,
        markedRange: markedRange
    ),
    replacementEnd == caretLocation
    else {
        return nil
    }

    return ManualHanjaTarget(
        sourceText: String(contextText[tokenRange]),
        replacementRange: NSRange(location: replacementLocation, length: replacementEnd - replacementLocation),
        anchorRange: NSRange(location: caretLocation, length: 0)
    )
}

private func manualHanjaDocumentOffset(
    forContextUTF16Offset offset: Int,
    committedRange: NSRange,
    markedRange: NSRange?
) -> Int? {
    if let markedRange {
        if offset <= committedRange.length {
            return committedRange.location + offset
        }

        let markedOffset = offset - committedRange.length
        guard markedOffset <= markedRange.length else {
            return nil
        }

        return markedRange.location + markedOffset
    }

    guard offset <= committedRange.length else {
        return nil
    }

    return committedRange.location + offset
}

private func manualHanjaTrailingTokenRange(in text: String) -> Range<String.Index>? {
    guard let lastCharacter = text.last,
          lastCharacter.isHangul
    else {
        return nil
    }

    var start = text.endIndex
    while start > text.startIndex {
        let previous = text.index(before: start)
        let ch = text[previous]
        guard ch.isHangul else {
            break
        }
        start = previous
    }

    return start..<text.endIndex
}

extension Character {
    var isHangul: Bool {
        unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (0xAC00...0xD7A3).contains(v)   // Hangul Syllables
                || (0x3131...0x318E).contains(v)    // Hangul Compatibility Jamo
                || (0x1100...0x11FF).contains(v)    // Hangul Jamo
                || (0xA960...0xA97C).contains(v)    // Hangul Jamo Extended-A
                || (0xD7B0...0xD7FB).contains(v)    // Hangul Jamo Extended-B
        }
    }
}
