// Non-activating candidate picker panel for manual Hanja conversion.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import SwiftUI

@MainActor
final class HanjaCandidatePanelController {
    static let shared = HanjaCandidatePanelController()

    private enum Layout {
        static let minPanelWidth: CGFloat = 176
        static let maxPanelWidth: CGFloat = 560
        static let emptyHeight: CGFloat = 96
        static let noticeHeight: CGFloat = 58
        static let noticeDetailHeight: CGFloat = 76
        static let rowHeight: CGFloat = 30
        static let candidateRowSpacing: CGFloat = 3
        static let visibleCandidateCount: CGFloat = 10
        static let contentVerticalPadding: CGFloat = 14
        static let candidatePanelHeight: CGFloat = (rowHeight * visibleCandidateCount)
            + (candidateRowSpacing * (visibleCandidateCount - 1))
            + contentVerticalPadding
        static let candidateFooterHeight: CGFloat = 42
        static let gapFromText: CGFloat = 2
        static let cornerRadius: CGFloat = 15
        static let minContentHeight: CGFloat = 1
        static let horizontalInset: CGFloat = 6
        static let verticalInset: CGFloat = 6
        static let panelHorizontalPadding: CGFloat = 14
        static let rowHorizontalPadding: CGFloat = 18
        static let shortcutLabelWidth: CGFloat = 18
        static let rowSpacing: CGFloat = 8
        static let rowSpacerWidth: CGFloat = 4
        static let userDefinedBadgeWidth: CGFloat = 18
        static let candidateFont = NSFont.systemFont(ofSize: 15)
        static let commentFont = NSFont.systemFont(ofSize: 11)
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HanjaCandidatePanelView>?
    private var selectionHandler: ((HanjaCandidatePanelSelection) -> Void)?

    private init() {}

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(
        content: ManualHanjaPanelContent,
        anchorRect: NSRect?,
        onSelect: ((HanjaCandidatePanelSelection) -> Void)? = nil
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        selectionHandler = onSelect
        updateContentView(content: content, in: panel)
        panel.level = .popUpMenu
        updatePanelFrame(panel, desiredContentSize: panelSize(for: content), anchorRect: anchorRect)
        panel.orderFrontRegardless()
    }

    func hide() {
        selectionHandler = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.minPanelWidth, height: Layout.emptyHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func updateContentView(content: ManualHanjaPanelContent, in panel: NSPanel) {
        let rootView = HanjaCandidatePanelView(content: content) { [weak self] selection in
            self?.handleSelection(selection)
        }

        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = Layout.cornerRadius
        contentView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        panel.contentView = contentView
        self.hostingView = hostingView
    }

    private func handleSelection(_ selection: HanjaCandidatePanelSelection) {
        let handler = selectionHandler
        hide()
        handler?(selection)
    }

    private func panelSize(for content: ManualHanjaPanelContent) -> NSSize {
        switch content {
        case .candidates(let state):
            if state.candidates.isEmpty {
                return NSSize(width: Layout.minPanelWidth, height: Layout.emptyHeight)
            }

            return NSSize(
                width: panelWidth(for: state),
                height: Layout.candidatePanelHeight + Layout.candidateFooterHeight
            )
        case .notice(let state):
            let height = state.detail?.isEmpty == false
                ? Layout.noticeDetailHeight
                : Layout.noticeHeight
            return NSSize(width: Layout.minPanelWidth, height: height)
        }
    }

    private func panelWidth(for state: HanjaCandidatePanelState) -> CGFloat {
        let maxCandidateWidth = state.candidates.reduce(CGFloat.zero) { currentMax, candidate in
            max(currentMax, rowWidth(for: candidate))
        }

        return min(max(maxCandidateWidth, Layout.minPanelWidth), Layout.maxPanelWidth)
    }

    private func rowWidth(for candidate: HanjaCandidate) -> CGFloat {
        var width = Layout.panelHorizontalPadding
            + Layout.rowHorizontalPadding
            + Layout.shortcutLabelWidth
            + Layout.rowSpacing
            + stringWidth(candidate.value, font: Layout.candidateFont)
            + Layout.rowSpacerWidth

        if candidate.source == .userDefined {
            width += Layout.userDefinedBadgeWidth
        }

        if !candidate.comment.isEmpty {
            width += Layout.rowSpacing
                + stringWidth(candidate.comment, font: Layout.commentFont)
        }

        return ceil(width)
    }

    private func stringWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else {
            return 0
        }

        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func updatePanelFrame(
        _ panel: NSPanel,
        desiredContentSize: NSSize,
        anchorRect: NSRect?
    ) {
        let anchorRect = anchorRect ?? fallbackAnchorRect()
        let screen = screen(containing: anchorRect) ?? screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            panel.setContentSize(desiredContentSize)
            center(panel)
            return
        }

        let visibleFrame = screen.visibleFrame
        let fittedWidth = min(
            desiredContentSize.width,
            max(visibleFrame.width - (Layout.horizontalInset * 2), 160)
        )
        let maxHeight = max(
            visibleFrame.height - (Layout.verticalInset * 2),
            Layout.minContentHeight
        )
        let fittedHeight = min(desiredContentSize.height, maxHeight)
        panel.setContentSize(NSSize(width: fittedWidth, height: fittedHeight))

        let clampedX = min(
            max(anchorRect.maxX, visibleFrame.minX + Layout.horizontalInset),
            max(
                visibleFrame.minX + Layout.horizontalInset,
                visibleFrame.maxX - panel.frame.width - Layout.horizontalInset
            )
        )

        let bottomSafe = visibleFrame.minY + Layout.verticalInset
        let topSafe = visibleFrame.maxY - Layout.verticalInset
        let visualBottomY = anchorRect.minY - anchorRect.height
        let visualTopY = anchorRect.minY
        let belowY = visualBottomY - panel.frame.height - Layout.gapFromText
        let aboveY = visualTopY + Layout.gapFromText
        let preferredY: CGFloat
        if belowY >= bottomSafe {
            preferredY = belowY
        } else if aboveY + panel.frame.height <= topSafe {
            preferredY = aboveY
        } else {
            let spaceBelow = max(visualBottomY - bottomSafe - Layout.gapFromText, 0)
            let spaceAbove = max(topSafe - visualTopY - Layout.gapFromText, 0)
            preferredY = spaceBelow >= spaceAbove ? belowY : aboveY
        }
        let clampedY = min(
            max(preferredY, bottomSafe),
            max(
                bottomSafe,
                topSafe - panel.frame.height
            )
        )
        let origin = CGPoint(
            x: clampedX,
            y: clampedY
        )

        panel.setFrameOrigin(origin)
    }

    private func fallbackAnchorRect() -> NSRect {
        NSRect(
            x: NSEvent.mouseLocation.x,
            y: NSEvent.mouseLocation.y,
            width: 0,
            height: 18
        )
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.intersects(rect)
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }
}
