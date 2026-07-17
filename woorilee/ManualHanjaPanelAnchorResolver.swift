// Anchor-rect probing to place the Hanja panel near the caret.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import IMKSwift

struct ManualHanjaPanelAnchorProbe {
    let range: NSRange
    let actualRange: NSRange
    let rect: NSRect
    /// Line-height rect queried for the winning probe only; `.zero` when not queried.
    let lineRect: NSRect
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

    /// `attributes(forCharacterIndex:lineHeightRectangle:)` takes an index "relative to the
    /// inline session" (IMKInputSession.h); with no inline session the index "should be 0,
    /// which indicates that the information should be taken from the current selection".
    /// Convert a document-absolute index into that space.
    static func inlineSessionIndex(forDocumentIndex documentIndex: Int, markedRange: NSRange) -> Int {
        guard markedRange.location != NSNotFound else {
            return 0
        }
        return min(max(documentIndex - markedRange.location, 0), markedRange.length)
    }

    @MainActor
    static func resolve(
        content: ManualHanjaPanelContent,
        client: any IMKTextInput
    ) -> ManualHanjaPanelAnchorResolution {
        let selectedRange = client.selectedRange()
        let markedRange = client.markedRange()
        let ranges = anchorCandidateRanges(
            for: content,
            markedRange: markedRange,
            selectedRange: selectedRange
        )
        let screenFrames = NSScreen.screens.map(\.frame)
        var probes: [ManualHanjaPanelAnchorProbe] = []

        for range in ranges {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let rect = client.firstRect(forCharacterRange: range, actualRange: &actualRange)
            let isValid = isValidAnchorRect(rect, screenFrames: screenFrames)
            var lineRect = NSRect.zero
            if isValid, range.location != NSNotFound {
                lineRect = reverseLineHeightRect(
                    from: inlineSessionIndex(forDocumentIndex: range.location, markedRange: markedRange),
                    client: client,
                    screenFrames: screenFrames
                ) ?? .zero
            }
            probes.append(
                ManualHanjaPanelAnchorProbe(
                    range: range,
                    actualRange: actualRange,
                    rect: rect,
                    lineRect: lineRect,
                    isValid: isValid
                )
            )

            if isValid {
                let anchor = reconciledAnchorRect(
                    rect: rect,
                    lineRect: lineRect,
                    screenFrames: screenFrames
                )
                return ManualHanjaPanelAnchorResolution(rect: anchor, probes: probes)
            }
        }

        // All firstRect candidates failed — fall back to vChewing's reverse line-height search.
        if let caretIndex = caretCharacterIndex(for: content, selectedRange: selectedRange),
           let rect = reverseLineHeightRect(
               from: inlineSessionIndex(forDocumentIndex: caretIndex, markedRange: markedRange),
               client: client,
               screenFrames: screenFrames
           ) {
            return ManualHanjaPanelAnchorResolution(rect: rect, probes: probes)
        }

        return ManualHanjaPanelAnchorResolution(rect: nil, probes: probes)
    }

    /// Some TextKit 2 hosts (Notes, TextEdit) return a flipped rect from
    /// `firstRect(forCharacterRange:)`: `origin.y` is the line's *top* edge, so the rect sits
    /// one line height above the real line box and the panel ends up covering the text.
    /// `attributes(forCharacterIndex:lineHeightRectangle:)` reports the correct bottom-origin
    /// line box in those hosts (it is the API mature IMK IMEs position with), so when it looks
    /// healthy, adopt its vertical band and keep `firstRect`'s horizontal geometry.
    static func reconciledAnchorRect(
        rect: NSRect,
        lineRect: NSRect,
        screenFrames: [NSRect]
    ) -> NSRect {
        if isValidAnchorRect(lineRect, screenFrames: screenFrames),
           lineRect.height >= minimumLineHeight {
            return NSRect(x: rect.minX, y: lineRect.minY, width: rect.width, height: lineRect.height)
        }

        // Line rect unusable as a position, but its height can still repair a too-short
        // `firstRect` while keeping the original horizontal position and line bottom.
        if rect.height < minimumLineHeight, lineRect.height >= minimumLineHeight {
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: lineRect.height)
        }

        return rect
    }

    /// Walk the start index backwards, asking for the line-height rectangle at each index until a
    /// valid one appears (vChewing's `lineHeightRect(u16Cursor:)`). The index is relative to the
    /// inline session — the same space vChewing's `lineHeightRect(u16Cursor:)` walks with its
    /// composition-buffer cursor — not a document-absolute offset.
    @MainActor
    static func reverseLineHeightRect(
        from startIndex: Int,
        client: any IMKTextInput,
        screenFrames: [NSRect]
    ) -> NSRect? {
        var index = startIndex
        let lowerBound = max(startIndex - maxReverseSearchSteps, 0)

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
