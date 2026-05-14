// About window controller for the woorilee input method.
//     Copyright (C) 2026 Seungjin Lee.

import AppKit
import Sparkle

@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "우리입력기에 관하여"
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()

        super.init(window: window)

        window.contentView = buildContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 260))

        let icon = NSImageView(frame: NSRect(x: 110, y: 170, width: 60, height: 60))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: bundleDisplayName)
        nameLabel.font = .boldSystemFont(ofSize: 14)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 140, width: 280, height: 20)
        container.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: versionString)
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: 118, width: 280, height: 16)
        container.addSubview(versionLabel)

        let copyrightLabel = NSTextField(labelWithString: copyrightString)
        copyrightLabel.font = .systemFont(ofSize: 10)
        copyrightLabel.textColor = .tertiaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.frame = NSRect(x: 0, y: 96, width: 280, height: 14)
        container.addSubview(copyrightLabel)

        let separator = NSBox(frame: NSRect(x: 20, y: 72, width: 240, height: 1))
        separator.boxType = .separator
        container.addSubview(separator)

        let updateButton = NSButton(
            title: "업데이트 확인…",
            target: self,
            action: #selector(checkForUpdates(_:))
        )
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .regular
        updateButton.sizeToFit()
        let buttonWidth = updateButton.frame.width
        updateButton.frame = NSRect(
            x: (280 - buttonWidth) / 2,
            y: 30,
            width: buttonWidth,
            height: 28
        )
        container.addSubview(updateButton)

        return container
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    // MARK: - Bundle info

    private var bundleDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "우리입력기"
    }

    private var versionString: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "버전 \(marketing) (\(build))"
    }

    private var copyrightString: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
