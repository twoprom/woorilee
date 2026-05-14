//
//  ManualHanjaModels.swift
//  woorilee
//

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
          !lastCharacter.isWhitespace,
          !isManualHanjaDelimiter(lastCharacter)
    else {
        return nil
    }

    var start = text.endIndex
    while start > text.startIndex {
        let previous = text.index(before: start)
        let ch = text[previous]
        guard !ch.isWhitespace, !isManualHanjaDelimiter(ch) else {
            break
        }
        start = previous
    }

    return start..<text.endIndex
}

private func isManualHanjaDelimiter(_ ch: Character) -> Bool {
    switch ch {
    case "(", ")", "[", "]", "{", "}",
         "\"", "'",
         "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",  // "", ''
         "「", "」", "『", "』", "【", "】", "〔", "〕", "〈", "〉", "《", "》":
        return true
    default:
        return false
    }
}
