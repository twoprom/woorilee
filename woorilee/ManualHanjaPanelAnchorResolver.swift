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
    @MainActor
    static func resolve(
        content: ManualHanjaPanelContent,
        client: any IMKTextInput
    ) -> ManualHanjaPanelAnchorResolution {
        let ranges = anchorCandidateRanges(
            for: content,
            markedRange: client.markedRange(),
            selectedRange: client.selectedRange()
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
                return ManualHanjaPanelAnchorResolution(rect: rect, probes: probes)
            }
        }

        return ManualHanjaPanelAnchorResolution(rect: nil, probes: probes)
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
