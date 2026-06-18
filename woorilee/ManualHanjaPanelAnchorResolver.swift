// Anchor-rect probing to place the Hanja panel near the caret.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import IMKSwift

struct ManualHanjaPanelAnchorProbe {
    let range: NSRange
    let actualRange: NSRange
    let rect: NSRect
    let isValid: Bool
}

struct ManualHanjaPanelAnchorResolution {
    let rect: NSRect?
    let probes: [ManualHanjaPanelAnchorProbe]
}

enum ManualHanjaPanelAnchorResolver {
    /// A `firstRect` height below this is treated as suspect and augmented via the line-height API.
    static let minimumLineHeight: CGFloat = 8
    /// How far back the reverse line-height search walks before giving up.
    static let maxReverseSearchSteps = 8

    @MainActor
    static func resolve(
        content: ManualHanjaPanelContent,
        client: any IMKTextInput
    ) -> ManualHanjaPanelAnchorResolution {
        let selectedRange = client.selectedRange()
        let ranges = anchorCandidateRanges(
            for: content,
            markedRange: client.markedRange(),
            selectedRange: selectedRange
        )
        let screenFrames = NSScreen.screens.map(\.frame)
        var probes: [ManualHanjaPanelAnchorProbe] = []

        for range in ranges {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let rect = client.firstRect(forCharacterRange: range, actualRange: &actualRange)
            let isValid = isValidAnchorRect(rect, screenFrames: screenFrames)
            probes.append(
                ManualHanjaPanelAnchorProbe(
                    range: range,
                    actualRange: actualRange,
                    rect: rect,
                    isValid: isValid
                )
            )

            if isValid {
                let anchor = augmentedLineHeight(
                    of: rect,
                    characterIndex: range.location,
                    client: client
                )
                return ManualHanjaPanelAnchorResolution(rect: anchor, probes: probes)
            }
        }

        // All firstRect candidates failed — fall back to vChewing's reverse line-height search.
        if let caretIndex = caretCharacterIndex(for: content, selectedRange: selectedRange),
           let rect = reverseLineHeightRect(
               caretIndex: caretIndex,
               client: client,
               screenFrames: screenFrames
           ) {
            return ManualHanjaPanelAnchorResolution(rect: rect, probes: probes)
        }

        return ManualHanjaPanelAnchorResolution(rect: nil, probes: probes)
    }

    /// When `firstRect` returns a believable position but a too-short height, borrow the line
    /// height from `attributes(forCharacterIndex:lineHeightRectangle:)` while keeping the original
    /// horizontal position and line bottom (`minY`).
    @MainActor
    static func augmentedLineHeight(
        of rect: NSRect,
        characterIndex: Int,
        client: any IMKTextInput
    ) -> NSRect {
        guard rect.height < minimumLineHeight, characterIndex != NSNotFound else {
            return rect
        }

        var lineRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: max(characterIndex, 0),
            lineHeightRectangle: &lineRect
        )
        guard lineRect.height >= minimumLineHeight else {
            return rect
        }

        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: lineRect.height)
    }

    /// Walk the caret index backwards, asking for the line-height rectangle at each index until a
    /// valid one appears (vChewing's `lineHeightRect(u16Cursor:)`).
    @MainActor
    static func reverseLineHeightRect(
        caretIndex: Int,
        client: any IMKTextInput,
        screenFrames: [NSRect]
    ) -> NSRect? {
        var index = caretIndex
        let lowerBound = max(caretIndex - maxReverseSearchSteps, 0)

        while index >= lowerBound {
            var lineRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &lineRect)
            if isValidAnchorRect(lineRect, screenFrames: screenFrames) {
                return lineRect
            }
            index -= 1
        }

        return nil
    }

    /// UTF-16 index of the caret: the trailing edge of the content anchor (or selection).
    static func caretCharacterIndex(
        for content: ManualHanjaPanelContent,
        selectedRange: NSRange
    ) -> Int? {
        let anchorRange = content.anchorRange
        if anchorRange.location != NSNotFound {
            return anchorRange.location + anchorRange.length
        }
        if selectedRange.location != NSNotFound {
            return selectedRange.location + selectedRange.length
        }
        return nil
    }

    static func anchorCandidateRanges(
        for content: ManualHanjaPanelContent,
        markedRange: NSRange,
        selectedRange: NSRange
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        appendRange(content.anchorRange, to: &ranges)

        if markedRange.location != NSNotFound, markedRange.length > 0 {
            appendRange(markedRange, to: &ranges)
        }

        if case .candidates(let state) = content,
           let replacementRange = state.mode.manualReplacementRange {
            appendRange(replacementRange, to: &ranges)
        }

        appendRange(selectedRange, to: &ranges)
        return ranges
    }

    static func isValidAnchorRect(_ rect: NSRect, screenFrames: [NSRect]) -> Bool {
        let fields: [CGFloat] = [rect.minX, rect.minY, rect.width, rect.height]
        guard fields.allSatisfy(\.isFinite), rect.height >= 1 else {
            return false
        }

        let probe = NSPoint(x: rect.midX, y: rect.midY)
        return screenFrames.contains { $0.contains(probe) }
    }

    private static func appendRange(_ range: NSRange, to ranges: inout [NSRange]) {
        guard range.location != NSNotFound,
              !ranges.contains(range)
        else {
            return
        }

        ranges.append(range)
    }
}
