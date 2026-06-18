// Pure placement math for the Hanja candidate panel.
//     Copyright (C) 2026 Seungjin Lee.

import CoreGraphics
import Foundation

/// Computes the candidate panel origin (bottom-left, screen coordinates) so that the
/// panel's top-left corner hangs from the caret's bottom-right corner.
///
/// Screen coordinates are y-up (origin at the main display's bottom-left). The anchor
/// `rect` is the glyph/line box of the caret with `minY` = line bottom, `maxY` = line top,
/// `maxX` = right edge of the caret (or composed text). See
/// `docs/plans/candidate-window-positioning.md` §3/§5.
enum CandidatePanelOriginCalculator {
    /// - Returns: the bottom-left origin to pass to `NSPanel.setFrameOrigin`.
    static func origin(
        anchorRect: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat,
        horizontalInset: CGFloat,
        verticalInset: CGFloat
    ) -> CGPoint {
        let anchorX = anchorRect.maxX        // text bar right edge
        let lineBottomY = anchorRect.minY    // line bottom — panel top hangs from here
        let lineTopY = anchorRect.maxY       // line top — reference when flipping above

        let clampedX = min(
            max(anchorX, visibleFrame.minX + horizontalInset),
            max(
                visibleFrame.minX + horizontalInset,
                visibleFrame.maxX - panelSize.width - horizontalInset
            )
        )

        let bottomSafe = visibleFrame.minY + verticalInset
        let topSafe = visibleFrame.maxY - verticalInset

        // Hang below the caret: panel top = lineBottomY - gap.
        let belowOriginY = lineBottomY - gap - panelSize.height
        // Flip above the caret: panel bottom = lineTopY + gap.
        let aboveOriginY = lineTopY + gap

        let preferredY: CGFloat
        if belowOriginY >= bottomSafe {
            preferredY = belowOriginY
        } else if aboveOriginY + panelSize.height <= topSafe {
            preferredY = aboveOriginY
        } else {
            // Neither side fits fully — pick whichever has more room.
            let spaceBelow = max((lineBottomY - gap) - bottomSafe, 0)
            let spaceAbove = max(topSafe - (lineTopY + gap), 0)
            preferredY = spaceBelow >= spaceAbove ? belowOriginY : aboveOriginY
        }

        let clampedY = min(
            max(preferredY, bottomSafe),
            max(bottomSafe, topSafe - panelSize.height)
        )

        return CGPoint(x: clampedX, y: clampedY)
    }
}
