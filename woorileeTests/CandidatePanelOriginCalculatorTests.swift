// Tests for candidate panel placement math.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import XCTest
@testable import woorilee

final class CandidatePanelOriginCalculatorTests: XCTestCase {
    private let gap: CGFloat = 4
    private let hInset: CGFloat = 6
    private let vInset: CGFloat = 6

    private func origin(
        anchor: NSRect,
        panel: NSSize,
        screen: NSRect
    ) -> CGPoint {
        CandidatePanelOriginCalculator.origin(
            anchorRect: anchor,
            panelSize: panel,
            visibleFrame: screen,
            gap: gap,
            horizontalInset: hInset,
            verticalInset: vInset
        )
    }

    func testBelowPlacementHangsFromLineBottom() {
        let anchor = NSRect(x: 100, y: 500, width: 0, height: 18)
        let panel = NSSize(width: 200, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let result = origin(anchor: anchor, panel: panel, screen: screen)

        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        // bottom-left origin
        XCTAssertEqual(result.y, 500 - gap - 120, accuracy: 0.001)
        // panel top sits gap below the line bottom
        XCTAssertEqual(result.y + panel.height, anchor.minY - gap, accuracy: 0.001)
    }

    func testFlipsAboveWhenBelowDoesNotFit() {
        let anchor = NSRect(x: 100, y: 20, width: 0, height: 18)
        let panel = NSSize(width: 200, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let result = origin(anchor: anchor, panel: panel, screen: screen)

        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        // panel bottom sits gap above the line top
        XCTAssertEqual(result.y, anchor.maxY + gap, accuracy: 0.001)
    }

    func testClampsToRightEdge() {
        let anchor = NSRect(x: 1430, y: 500, width: 0, height: 18)
        let panel = NSSize(width: 200, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let result = origin(anchor: anchor, panel: panel, screen: screen)

        XCTAssertEqual(result.x, screen.maxX - panel.width - hInset, accuracy: 0.001)
    }

    func testUsesRightEdgeOfComposedTextAsXAnchor() {
        let anchor = NSRect(x: 100, y: 500, width: 40, height: 18)
        let panel = NSSize(width: 200, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let result = origin(anchor: anchor, panel: panel, screen: screen)

        // x anchored to maxX (right edge), not minX
        XCTAssertEqual(result.x, anchor.maxX, accuracy: 0.001)
    }

    func testClampsToProvidedScreenFrameForSecondaryDisplay() {
        let anchor = NSRect(x: 1500, y: 500, width: 0, height: 18)
        let panel = NSSize(width: 200, height: 120)
        // Secondary display to the right of the primary.
        let screen = NSRect(x: 1440, y: 0, width: 1440, height: 900)

        let result = origin(anchor: anchor, panel: panel, screen: screen)

        // Positioned on the secondary display, not clamped against the primary frame.
        XCTAssertEqual(result.x, 1500, accuracy: 0.001)
        XCTAssertEqual(result.y, 500 - gap - 120, accuracy: 0.001)
    }
}
